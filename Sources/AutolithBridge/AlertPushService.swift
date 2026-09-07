import Foundation
import BridgeCore

final class AlertPushService: @unchecked Sendable {
    private struct Device: Codable {
        let token: String
        let host: String
        var expires: Date
        var working: Set<String> = []
        var delivered: [String: String] = [:]
        var revision: UUID?
    }
    private let queue = DispatchQueue(label: "autolith.alerts")
    private let file: URL
    private let push: PushService
    private let call: ([String: Any]) throws -> [String: Any]
    private var devices: [String: Device]
    private var timer: DispatchSourceTimer?
    private var polling = false

    init(file: URL, push: PushService, call: @escaping ([String: Any]) throws -> [String: Any]) throws {
        self.file = file; self.push = push; self.call = call
        devices = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode([String: Device].self, from: Data(contentsOf: file)) : [:]
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 10)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer; timer.resume()
    }

    func register(_ object: [String: Any]) throws {
        guard push.enabled else { throw BridgeError.invalid("APNs is not configured on this Mac.") }
        guard let token = object["pushToken"] as? String, (32...512).contains(token.count), token.count.isMultiple(of: 2), token.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let host = object["host"] as? String, let url = URLComponents(string: host), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw BridgeError.invalid("Invalid notification registration.") }
        try queue.sync {
            devices = devices.filter { $0.value.expires > Date() }
            guard devices[token] != nil || devices.count < 16 else { throw BridgeError.invalid("Too many notification devices.") }
            if devices[token]?.host != host { devices[token] = Device(token: token, host: host, expires: Date().addingTimeInterval(7 * 86400)) }
            devices[token]?.expires = Date().addingTimeInterval(7 * 86400)
            try save()
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(devices).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func watch(_ sessionID: String) throws {
        guard push.enabled else { return }
        let events = try call(["operation": "transcript", "id": sessionID, "after": 0])["events"] as? [[String: Any]] ?? []
        let previous = events.last(where: { $0["role"] as? String == "assistant" })?["id"] as? String
        try queue.sync {
            for key in devices.keys {
                devices[key]?.working.insert(sessionID)
                devices[key]?.delivered[sessionID] = previous
                devices[key]?.revision = UUID()
            }
            try save()
        }
    }

    private func poll() {
        guard push.enabled, !polling else { return }
        devices = devices.filter { $0.value.expires > Date() }
        guard !devices.isEmpty else { return }
        polling = true
        let pending = devices
        Task {
            defer { queue.async { self.polling = false } }
            do {
                let sessions = try call(["operation": "list"])["sessions"] as? [[String: Any]] ?? []
                for (key, original) in pending {
                    var device = original
                    for session in sessions {
                        guard let id = session["id"] as? String else { continue }
                        let state = session["state"] as? String ?? ""
                        let working = ["active", "working", "starting", "cancelling"].contains(state) || (session["jobs"] as? Int ?? 0) > 0 || (session["queued"] as? Int ?? 0) > 0
                        if working { device.working.insert(id); continue }
                        guard device.working.contains(id) else { continue }
                        let events = try call(["operation": "transcript", "id": id, "after": 0])["events"] as? [[String: Any]] ?? []
                        let start = events.lastIndex { $0["role"] as? String == "user" }.map { $0 + 1 } ?? 0
                        guard let answer = events.dropFirst(start).last(where: { $0["role"] as? String == "assistant" && !($0["text"] as? String ?? "").isEmpty }),
                              let eventID = answer["id"] as? String, let text = answer["text"] as? String else { continue }
                        if device.delivered[id] == eventID { continue }
                        guard queue.sync(execute: { self.devices[key]?.revision == original.revision }) else { break }
                        let payload: [String: Any] = ["aps": ["alert": ["title": session["title"] as? String ?? "Autolith", "body": String(text.prefix(300))], "sound": "default", "category": "autolith.message", "thread-id": device.host + "#" + id], "host": device.host, "sessionID": id, "eventID": eventID]
                        let status = try await push.sendAlert(payload, token: device.token)
                        if status == 200 { device.delivered[id] = eventID; device.working.remove(id) }
                        else if status == 410 { device.expires = .distantPast; break }
                        else { fputs("Response notification rejected by APNs; HTTP \(status).\n", stderr) }
                    }
                    device.working.formIntersection(Set(sessions.compactMap { $0["id"] as? String }))
                    let updated = device
                    queue.async {
                        guard self.devices[key]?.host == original.host, self.devices[key]?.revision == original.revision else { return }
                        let expires = self.devices[key]!.expires
                        self.devices[key] = updated
                        self.devices[key]?.expires = min(expires, updated.expires)
                        do { try self.save() } catch { fputs("Could not persist notification progress.\n", stderr) }
                    }
                }
            } catch { fputs("Response notification poll failed; will retry.\n", stderr) }
        }
    }
}
