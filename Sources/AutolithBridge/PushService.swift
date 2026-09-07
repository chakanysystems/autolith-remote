import Foundation
import CryptoKit
import ClientCore

// Push credentials stay on the Mac. The only outbound destinations are Apple's APNs hosts.
final class PushService: @unchecked Sendable {
    private struct Registration {
        let token: String
        let expires: Date
        var lastState: WorkSummary?
        var lastSent = Date.distantPast
    }
    private struct Configuration {
        let key: P256.Signing.PrivateKey
        let keyID: String
        let teamID: String
        let bundleID: String
        let sandbox: Bool
    }
    private let configuration: Configuration?
    private let snapshot: () throws -> Data
    private let queue = DispatchQueue(label: "autolith.push")
    private var registrations: [String: Registration] = [:]
    private var polling = false
    private var cachedJWT: (value: String, created: Date)?
    private var timer: DispatchSourceTimer?
    var enabled: Bool { configuration != nil }

    init(environment: [String: String], snapshot: @escaping () throws -> Data) throws {
        self.snapshot = snapshot
        if let path = environment["AUTOLITH_APNS_KEY_FILE"] {
            guard let keyID = environment["AUTOLITH_APNS_KEY_ID"], !keyID.isEmpty,
                  let team = environment["AUTOLITH_APNS_TEAM_ID"], !team.isEmpty,
                  let bundle = environment["AUTOLITH_APNS_BUNDLE_ID"], !bundle.isEmpty else {
                throw NSError(domain: "AutolithPush", code: 1, userInfo: [NSLocalizedDescriptionKey: "APNs requires KEY_ID, TEAM_ID, and BUNDLE_ID alongside KEY_FILE."])
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                throw NSError(domain: "AutolithPush", code: 2, userInfo: [NSLocalizedDescriptionKey: "APNs key must be an owned regular file with mode 0600."])
            }
            configuration = Configuration(key: try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: path)),
                                          keyID: keyID, teamID: team, bundleID: bundle,
                                          sandbox: environment["AUTOLITH_APNS_ENVIRONMENT"] != "production")
        } else { configuration = nil }
        if enabled {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 15)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume(); self.timer = timer
        }
    }
    func register(_ object: [String: Any]) throws {
        guard enabled else { throw NSError(domain: "AutolithPush", code: 3, userInfo: [NSLocalizedDescriptionKey: "APNs is not configured on this Mac."]) }
        guard let id = object["activityId"] as? String, !id.isEmpty, id.count <= 128,
              let token = object["pushToken"] as? String, (32...512).contains(token.count),
              token.count.isMultiple(of: 2), token.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw NSError(domain: "AutolithPush", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid Live Activity registration."])
        }
        try queue.sync {
            registrations = registrations.filter { $0.value.expires > Date() }
            guard registrations[id] != nil || registrations.count < 16 else {
                throw NSError(domain: "AutolithPush", code: 5, userInfo: [NSLocalizedDescriptionKey: "Too many Live Activity registrations."])
            }
            if registrations[id]?.token != token {
                registrations[id] = Registration(token: token, expires: Date().addingTimeInterval(8 * 3600))
            }
        }
    }
    private func tick() {
        registrations = registrations.filter { $0.value.expires > Date() }
        guard !polling, !registrations.isEmpty, let configuration else { return }
        polling = true
        let pending = registrations
        Task {
            defer { queue.async { self.polling = false } }
            do {
                let summary = try WorkSummary.decodeSessions(snapshot())
                for (id, registration) in pending {
                    guard registration.lastState != summary || Date().timeIntervalSince(registration.lastSent) > 45 else { continue }
                    let content = summary.sessions == 0 ? (registration.lastState ?? summary).finished : summary
                    let status = try await send(content, token: registration.token, configuration: configuration)
                    queue.async {
                        guard self.registrations[id]?.token == registration.token else { return }
                        if status == 410 || status == 400 || (status == 200 && summary.sessions == 0) {
                            self.registrations[id] = nil
                        } else if status == 200 {
                            self.registrations[id]?.lastState = summary
                            self.registrations[id]?.lastSent = Date()
                        }
                    }
                    if status != 200 { fputs("Live Activity push rejected (HTTP \(status)). Check APNs configuration.\n", stderr) }
                }
            } catch { fputs("Live Activity update failed; will retry.\n", stderr) }
        }
    }
    func sendAlert(_ payload: [String: Any], token: String) async throws -> Int {
        guard let configuration else { throw NSError(domain: "AutolithPush", code: 3, userInfo: [NSLocalizedDescriptionKey: "APNs is not configured."]) }
        return try await sendPayload(payload, token: token, type: "alert", configuration: configuration)
    }

    private func send(_ state: WorkSummary, token: String, configuration: Configuration) async throws -> Int {
        let now = Int(Date().timeIntervalSince1970)
        let content = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
        var aps: [String: Any] = ["timestamp": now, "event": state.sessions == 0 ? "end" : "update", "content-state": content, "stale-date": now + 120]
        if state.sessions == 0 { aps.removeValue(forKey: "stale-date") }
        return try await sendPayload(["aps": aps], token: token, type: "liveactivity", configuration: configuration)
    }

    private func sendPayload(_ payload: [String: Any], token: String, type: String, configuration: Configuration) async throws -> Int {
        func base64url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let now = Int(Date().timeIntervalSince1970)
        let jwt: String = try queue.sync {
            if let cachedJWT, Date().timeIntervalSince(cachedJWT.created) < 1200 {
                return cachedJWT.value
            }
            let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": configuration.keyID])
            let claims = try JSONSerialization.data(withJSONObject: ["iss": configuration.teamID, "iat": now])
            let unsigned = base64url(header) + "." + base64url(claims)
            let jwt = unsigned + "." + base64url(try configuration.key.signature(for: Data(unsigned.utf8)).rawRepresentation)
            cachedJWT = (jwt, Date())
            return jwt
        }
        let host = configuration.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(token)")!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(type, forHTTPHeaderField: "apns-push-type")
        request.setValue(type == "alert" ? configuration.bundleID : configuration.bundleID + ".push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        request.setValue(type == "alert" ? "10" : "5", forHTTPHeaderField: "apns-priority")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
