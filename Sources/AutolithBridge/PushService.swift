import Foundation
import CryptoKit
import ClientCore
import BridgeCore

// Push credentials stay on the Mac. The only outbound destinations are Apple's APNs hosts.
final class PushService: @unchecked Sendable {
    private struct Registration {
        let token: String
        var expires: Date
        var revision = UUID()
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
    private var injectedSender: ((WorkSummary, String) async throws -> Int)?
    private var now: () -> Date = Date.init
    var enabled: Bool { configuration != nil || injectedSender != nil }

    /// No credentials, timer, or network needed for delivery/race tests.
    init(snapshot: @escaping () throws -> Data, sender: @escaping (WorkSummary, String) async throws -> Int, now: @escaping () -> Date = Date.init) {
        configuration = nil
        self.snapshot = snapshot
        injectedSender = sender
        self.now = now
    }
    init(environment: [String: String], snapshot: @escaping () throws -> Data) throws {
        self.snapshot = snapshot
        if let path = environment["AUTOLITH_APNS_KEY_FILE"] {
            guard let keyID = environment["AUTOLITH_APNS_KEY_ID"], !keyID.isEmpty,
                  let team = environment["AUTOLITH_APNS_TEAM_ID"], !team.isEmpty,
                  let bundle = environment["AUTOLITH_APNS_BUNDLE_ID"], !bundle.isEmpty else {
                throw NSError(domain: "AutolithPush", code: 1, userInfo: [NSLocalizedDescriptionKey: "APNs requires KEY_ID, TEAM_ID, and BUNDLE_ID alongside KEY_FILE."])
            }
            let data = try PrivateFile.readSecret(at: URL(fileURLWithPath: path), maximumBytes: 16384)
            guard let pem = String(data: data, encoding: .utf8) else { throw BridgeError.invalid("APNs key is not UTF-8.") }
            configuration = Configuration(key: try P256.Signing.PrivateKey(pemRepresentation: pem),
                                          keyID: keyID, teamID: team, bundleID: bundle,
                                          sandbox: environment["AUTOLITH_APNS_ENVIRONMENT"] != "production")
        } else { configuration = nil }
        if enabled {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 15)
            timer.setEventHandler { [weak self] in Task { await self?.pollOnce() } }
            timer.resume(); self.timer = timer
        }
    }
    func register(_ object: [String: Any], beforeMutation: () throws -> Void = {}) throws {
        guard enabled else { throw NSError(domain: "AutolithPush", code: 3, userInfo: [NSLocalizedDescriptionKey: "APNs is not configured on this Mac."]) }
        guard let id = object["activityId"] as? String, !id.isEmpty, id.count <= 128,
              let token = object["pushToken"] as? String, (32...512).contains(token.count),
              token.count.isMultiple(of: 2), token.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw NSError(domain: "AutolithPush", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid Live Activity registration."])
        }
        try queue.sync {
            try beforeMutation()
            registrations = registrations.filter { $0.value.expires > now() }
            guard registrations[id] != nil || registrations.count < 16 else {
                throw NSError(domain: "AutolithPush", code: 5, userInfo: [NSLocalizedDescriptionKey: "Too many Live Activity registrations."])
            }
            if registrations[id]?.token != token {
                registrations[id] = Registration(token: token, expires: now().addingTimeInterval(8 * 3600))
            }
            registrations[id]?.expires = now().addingTimeInterval(8 * 3600)
            registrations[id]?.revision = UUID()
        }
    }
    func pollOnce() async {
        let pending: [String: Registration] = queue.sync {
            registrations = registrations.filter { $0.value.expires > now() }
            guard enabled, !polling, !registrations.isEmpty else { return [:] }
            polling = true
            return registrations
        }
        guard !pending.isEmpty else { return }
        defer { queue.sync { polling = false } }
        do {
            let summary = try WorkSummary.decodeSessions(snapshot())
            for (id, registration) in pending {
                guard registration.lastState != summary || now().timeIntervalSince(registration.lastSent) > 45 else { continue }
                guard queue.sync(execute: { registrations[id]?.revision == registration.revision && (registrations[id]?.expires ?? .distantPast) > now() }) else { continue }
                let content = summary.sessions == 0 ? (registration.lastState ?? summary).finished : summary
                let status: Int
                if let injectedSender { status = try await injectedSender(content, registration.token) }
                else if let configuration { status = try await send(content, token: registration.token, configuration: configuration) }
                else { continue }
                queue.sync {
                    guard self.registrations[id]?.revision == registration.revision else { return }
                    if status == 410 || status == 400 || (status == 200 && summary.sessions == 0) {
                        self.registrations[id] = nil
                    } else if status == 200 {
                        self.registrations[id]?.lastState = summary
                        self.registrations[id]?.lastSent = now()
                    }
                }
                if status != 200 { fputs("Live Activity push rejected (HTTP \(status)). Check APNs configuration.\n", stderr) }
            }
        } catch { fputs("Live Activity update failed; will retry.\n", stderr) }
    }
    func sendAlert(_ payload: [String: Any], token: String, collapseID: String) async throws -> Int {
        guard let configuration else { throw NSError(domain: "AutolithPush", code: 3, userInfo: [NSLocalizedDescriptionKey: "APNs is not configured."]) }
        return try await sendPayload(payload, token: token, type: "alert", configuration: configuration, collapseID: collapseID)
    }

    private func send(_ state: WorkSummary, token: String, configuration: Configuration) async throws -> Int {
        let now = Int(Date().timeIntervalSince1970)
        let content = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
        var aps: [String: Any] = ["timestamp": now, "event": state.sessions == 0 ? "end" : "update", "content-state": content, "stale-date": now + 120]
        if state.sessions == 0 { aps.removeValue(forKey: "stale-date") }
        return try await sendPayload(["aps": aps], token: token, type: "liveactivity", configuration: configuration)
    }

    private func sendPayload(_ payload: [String: Any], token: String, type: String, configuration: Configuration, collapseID: String? = nil) async throws -> Int {
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
        if let collapseID { request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
