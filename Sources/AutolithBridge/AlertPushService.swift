import Foundation
import BridgeCore
import ClientCore

/// Delivery is at least once: a crash after APNs accepts but before progress is
/// persisted can resend an event. Stable collapse IDs coalesce pending retries;
/// APNs does not guarantee deduplication after delivery.
final class AlertPushService: @unchecked Sendable {
    private struct Device: Codable {
        let token: String
        let host: String
        var expires: Date
        var working: Set<String> = []
        var delivered: [String: String] = [:]
        var revision: UUID? = UUID()
    }
    private let queue = DispatchQueue(label: "autolith.alerts")
    private let file: URL
    private let enabled: () -> Bool
    private let sender: ([String: Any], String, String) async throws -> Int
    private let call: ([String: Any]) throws -> [String: Any]
    private let now: () -> Date
    private var devices: [String: Device]
    private var timer: DispatchSourceTimer?
    private var polling = false
    private static let maximumStateBytes = 4 * 1024 * 1024
    private static let maximumSessions = 256

    private static func boundedIdentity(_ value: String, maximum: Int = 256) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
    }

    /// Bound by encoded JSON bytes, including escaping and all APNs metadata.
    static func payload(host: String, sessionID: String, eventID: String, title: String, text: String) throws -> [String: Any] {
        guard boundedIdentity(host, maximum: 512), boundedIdentity(sessionID), boundedIdentity(eventID) else {
            throw BridgeError.invalid("Notification identity is too large.")
        }
        func prefix(_ value: String, bytes: Int) -> String {
            var result = String.UnicodeScalarView()
            var count = 0
            for scalar in value.unicodeScalars {
                let size = scalar.utf8.count
                guard count + size <= bytes else { break }
                result.append(scalar)
                count += size
            }
            return String(result)
        }
        let identity = NotificationEventIdentity.id(host: host, sessionID: sessionID, eventID: eventID)
        var heading = prefix(title, bytes: 512)
        var preview = prefix(text, bytes: 1200)
        while true {
            let result: [String: Any] = ["aps": ["alert": ["title": heading, "body": preview], "sound": "default", "category": "autolith.message", "thread-id": host + "#" + sessionID], "host": host, "sessionID": sessionID, "eventID": eventID, "notificationID": identity]
            if try JSONSerialization.data(withJSONObject: result).count <= 4096 { return result }
            if !preview.isEmpty { preview.removeLast() }
            else if !heading.isEmpty { heading.removeLast() }
            else { throw BridgeError.invalid("Notification identity exceeds the APNs payload limit.") }
        }
    }

    convenience init(file: URL, push: PushService, call: @escaping ([String: Any]) throws -> [String: Any]) throws {
        try self.init(file: file, enabled: { push.enabled }, sender: { payload, token, identity in
            try await push.sendAlert(payload, token: token, collapseID: identity)
        }, call: call)
    }

    init(file: URL, enabled: @escaping () -> Bool, sender: @escaping ([String: Any], String, String) async throws -> Int,
         call: @escaping ([String: Any]) throws -> [String: Any], now: @escaping () -> Date = Date.init, startTimer: Bool = true) throws {
        self.file = file; self.enabled = enabled; self.sender = sender; self.call = call; self.now = now
        devices = try DurableJSONFile.read(at: file, maximumBytes: Self.maximumStateBytes).map { try JSONDecoder().decode([String: Device].self, from: $0) } ?? [:]
        // Legacy registrations may have no revision. Never compare an absent
        // device's nil revision equal to one of those snapshots after revocation.
        for key in devices.keys where devices[key]?.revision == nil { devices[key]?.revision = UUID() }
        guard devices.count <= 16, devices.values.allSatisfy({ device in
            Self.boundedIdentity(device.host, maximum: 512) && device.working.count <= Self.maximumSessions && device.delivered.count <= Self.maximumSessions && device.working.allSatisfy { Self.boundedIdentity($0) } && device.delivered.allSatisfy { Self.boundedIdentity($0.key) && Self.boundedIdentity($0.value) }
        }) else { throw BridgeError.invalid("Notification state exceeds its limits.") }
        if startTimer {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 10)
            timer.setEventHandler { [weak self] in Task { await self?.pollOnce() } }
            self.timer = timer; timer.resume()
        }
    }

    private func identity(_ object: [String: Any]) throws -> (String, String) {
        guard let token = object["pushToken"] as? String, (32...512).contains(token.count), token.count.isMultiple(of: 2), token.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let host = object["host"] as? String, Self.boundedIdentity(host, maximum: 512), let url = URLComponents(string: host), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw BridgeError.invalid("Invalid notification registration.") }
        return (token.lowercased(), host)
    }

    func register(_ object: [String: Any], beforeMutation: () throws -> Void = {}) throws {
        guard enabled() else { throw BridgeError.invalid("APNs is not configured on this Mac.") }
        let (token, host) = try identity(object)
        try queue.sync {
            try beforeMutation()
            let previous = devices
            devices = devices.filter { $0.value.expires > now() }
            guard devices[token] != nil || devices.count < 16 else { throw BridgeError.invalid("Too many notification devices.") }
            if devices[token]?.host != host { devices[token] = Device(token: token, host: host, expires: now()) }
            devices[token]?.expires = now().addingTimeInterval(7 * 86400)
            devices[token]?.revision = UUID()
            do { try save() } catch { if !(error is DurableJSONFile.CommitError) { devices = previous }; throw error }
        }
    }

    /// Revocation works even when APNs has subsequently been disabled. A send
    /// already accepted by APNs cannot be recalled.
    func unregister(_ object: [String: Any], beforeMutation: () throws -> Void = {}) throws {
        let (token, host) = try identity(object)
        try queue.sync {
            try beforeMutation()
            guard devices[token]?.host == host else { return }
            let previous = devices.removeValue(forKey: token)
            do { try save() } catch { if !(error is DurableJSONFile.CommitError) { devices[token] = previous }; throw error }
        }
    }

    private func save() throws {
        let data = try JSONEncoder().encode(devices)
        guard data.count <= Self.maximumStateBytes else { throw BridgeError.invalid("Notification state exceeds its size limit.") }
        try DurableJSONFile.write(data, to: file)
    }

    func watch(_ sessionID: String, request: (([String: Any]) throws -> [String: Any])? = nil,
               beforeMutation: () throws -> Void = {}) throws {
        let call = request ?? self.call
        guard enabled() else { return }
        guard Self.boundedIdentity(sessionID) else { throw BridgeError.invalid("Invalid notification session identity.") }
        let events = try call(["operation": "transcript", "id": sessionID, "after": 0])["events"] as? [[String: Any]] ?? []
        let previous = events.last(where: { $0["role"] as? String == "assistant" })?["id"] as? String
        guard previous.map({ Self.boundedIdentity($0) }) ?? true else { throw BridgeError.invalid("Invalid notification event identity.") }
        try queue.sync {
            try beforeMutation()
            let old = devices
            guard devices.values.allSatisfy({ $0.working.contains(sessionID) || $0.working.count < Self.maximumSessions }),
                  devices.values.allSatisfy({ previous == nil || $0.delivered[sessionID] != nil || $0.delivered.count < Self.maximumSessions }) else {
                throw BridgeError.invalid("Too many watched notification sessions.")
            }
            for key in devices.keys {
                devices[key]?.working.insert(sessionID)
                devices[key]?.delivered[sessionID] = previous
                devices[key]?.revision = UUID()
            }
            do { try save() } catch { if !(error is DurableJSONFile.CommitError) { devices = old }; throw error }
        }
    }

    /// Explicit, awaitable polling seam for deterministic fake-sender tests.
    func pollOnce() async {
        let pending: [String: Device] = queue.sync {
            guard enabled(), !polling else { return [:] }
            devices = devices.filter { $0.value.expires > now() }
            guard !devices.isEmpty else { return [:] }
            polling = true
            return devices
        }
        guard !pending.isEmpty else { return }
        defer { queue.sync { polling = false } }
        do {
            let sessions = try call(["operation": "list"])["sessions"] as? [[String: Any]] ?? []
            let validIDs = Set(sessions.compactMap { $0["id"] as? String }.filter { Self.boundedIdentity($0) })
            for (key, original) in pending {
                var device = original
                device.working.formIntersection(validIDs)
                device.delivered = device.delivered.filter { validIDs.contains($0.key) }
                for session in sessions {
                    guard let id = session["id"] as? String, Self.boundedIdentity(id) else { continue }
                    let state = session["state"] as? String ?? ""
                    let working = ["active", "working", "starting", "cancelling"].contains(state) || (session["jobs"] as? Int ?? 0) > 0 || (session["queued"] as? Int ?? 0) > 0
                    if working {
                        if device.working.count < Self.maximumSessions { device.working.insert(id) }
                        continue
                    }
                    guard device.working.contains(id) else { continue }
                    let events = try call(["operation": "transcript", "id": id, "after": 0])["events"] as? [[String: Any]] ?? []
                    let start = events.lastIndex { $0["role"] as? String == "user" }.map { $0 + 1 } ?? 0
                    guard let answer = events.dropFirst(start).last(where: { $0["role"] as? String == "assistant" && !($0["text"] as? String ?? "").isEmpty }),
                          let eventID = answer["id"] as? String, Self.boundedIdentity(eventID), let text = answer["text"] as? String else { continue }
                    if device.delivered[id] == eventID { device.working.remove(id); continue }
                    guard queue.sync(execute: { self.devices[key]?.revision == original.revision && (self.devices[key]?.expires ?? .distantPast) > now() }) else { break }
                    let identity = NotificationEventIdentity.id(host: device.host, sessionID: id, eventID: eventID)
                    guard device.delivered[id] != nil || device.delivered.count < Self.maximumSessions else { continue }
                    let payload = try Self.payload(host: device.host, sessionID: id, eventID: eventID, title: session["title"] as? String ?? "Autolith", text: text)
                    let status = try await sender(payload, device.token, identity)
                    if status == 200 { device.delivered[id] = eventID; device.working.remove(id) }
                    else if status == 410 { device.expires = .distantPast; break }
                    else { fputs("Response notification rejected by APNs; HTTP \(status).\n", stderr) }
                }
                let updated = device
                try queue.sync {
                    // Never overwrite a renewal, watch, or revocation with stale results.
                    guard self.devices[key]?.revision == original.revision else { return }
                    let previous = devices[key]
                    devices[key] = updated
                    do { try save() } catch { if !(error is DurableJSONFile.CommitError) { devices[key] = previous }; throw error }
                }
            }
        } catch { fputs("Response notification poll failed; will retry.\n", stderr) }
    }
}
