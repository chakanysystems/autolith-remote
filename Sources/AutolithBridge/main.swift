import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import BridgeCore

// The listener accepts loopback only. Tailscale Serve owns remote HTTPS.
let environment = ProcessInfo.processInfo.environment
let executable = environment["AUTOLITH_EXECUTABLE"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nix-profile/bin/autolith").path
try BackendChild.prepareReaping()
let backend = BackendPool(executable: executable)
let transcripts = TranscriptService()
guard let tokenPath = environment["AUTOLITH_BRIDGE_TOKEN_FILE"] else {
    fputs("Set AUTOLITH_BRIDGE_TOKEN_FILE to a private file containing a random token.\n", stderr); exit(64)
}
let tokenData = try PrivateFile.readSecret(at: URL(fileURLWithPath: tokenPath))
guard let tokenText = String(data: tokenData, encoding: .utf8) else {
    fputs("Token file must contain UTF-8 text.\n", stderr); exit(64)
}
let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
guard token.utf8.count >= 32 else { fputs("Token must contain at least 32 random characters.\n", stderr); exit(64) }
let queue = DispatchQueue(label: "autolith.bridge")
let workers = DispatchQueue(label: "autolith.operations", attributes: .concurrent)
let slots = DispatchSemaphore(value: 4)
let streamSlots = DispatchSemaphore(value: 4)

func authorized(_ authorization: String) -> Bool {
    let supplied = Array(authorization.utf8), expected = Array("Bearer \(token)".utf8)
    var difference = supplied.count ^ expected.count
    for index in expected.indices { difference |= Int(expected[index] ^ (index < supplied.count ? supplied[index] : 0)) }
    return difference == 0
}
// Override the loopback port for isolated integration tests or a second companion.
let port = UInt16(environment["AUTOLITH_BRIDGE_PORT"] ?? "4318") ?? 4318
let listener = BridgeListener(queue: queue)

let pushService = try PushService(environment: environment) {
    try executeAutolith(Data("{\"operation\":\"list\"}".utf8))
}
let messageService = try MessageService(file: URL(fileURLWithPath: tokenPath).deletingLastPathComponent().appendingPathComponent("messages/outbox.json")) { object in
    let data = try executeAutolith(JSONSerialization.data(withJSONObject: object))
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.invalid("Invalid backend response.") }
    if let error = result["error"] as? String { throw BridgeError.invalid(error) }
    return result
}
let alertService = try AlertPushService(file: URL(fileURLWithPath: tokenPath).deletingLastPathComponent().appendingPathComponent("messages/devices.json"), push: pushService) { object in
    let data = try executeAutolith(JSONSerialization.data(withJSONObject: object))
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.invalid("Invalid backend response.") }
    if let error = result["error"] as? String { throw BridgeError.invalid(error) }
    return result
}

let idleTimeoutText = environment["AUTOLITH_IDLE_SESSION_TIMEOUT_SECONDS"] ?? "1800"
guard let idleTimeout = Double(idleTimeoutText), idleTimeout.isFinite, idleTimeout >= 60 else {
    fputs("AUTOLITH_IDLE_SESSION_TIMEOUT_SECONDS must be at least 60.\n", stderr); exit(64)
}
let idleSessions = IdleSessionService(timeout: idleTimeout) { object in
    let data = try execute(JSONSerialization.data(withJSONObject: object))
    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BridgeError.invalid("Invalid cleanup response")
    }
    if let error = reply["error"] as? String { throw BridgeError.invalid(error) }
    return reply
}

func execute(_ body: Data, context: BackendRequestContext = BackendRequestContext()) throws -> Data {
    try context.check()
    let request: ([String: Any]) throws -> [String: Any] = { object in
        let data = try executeAutolith(JSONSerialization.data(withJSONObject: object), context: context)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.invalid("Invalid backend response.") }
        if let error = result["error"] as? String { throw BridgeError.invalid(error) }
        return result
    }
    if let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
        if let operation = object["operation"] as? String,
           ["tell", "resume", "message-send", "pause"].contains(operation),
           let id = object["id"] as? String { idleSessions.activity(id) }
        if var result = try messageService.handle(object, request: request, beforeMutation: { try context.check() }) {
            if object["operation"] as? String == "message-send", let id = object["id"] as? String {
                do {
                    try alertService.watch(id, request: request, beforeMutation: { try context.check() })
                    result["notificationWatch"] = true
                } catch {
                    result["notificationWatch"] = false
                    fputs("Could not register response notification watch. Local completion delivery is required.\n", stderr)
                }
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
        if object["operation"] as? String == "notification-register" {
            try alertService.register(object, beforeMutation: { try context.check() })
            return Data("{\"ok\":true}".utf8)
        }
        if object["operation"] as? String == "notification-unregister" {
            try alertService.unregister(object, beforeMutation: { try context.check() })
            return Data("{\"ok\":true}".utf8)
        }
        if object["operation"] as? String == "transcript-sync", let id = object["id"] as? String {
            let raw = try executeAutolith(JSONSerialization.data(withJSONObject: ["operation": "transcript", "id": id, "after": 0]), context: context)
            let reply = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
            if reply["error"] != nil { return raw }
            let decorated = messageService.decorateTranscript(reply, sessionID: id)
            return try JSONSerialization.data(withJSONObject: transcripts.response(sessionID: id, events: decorated["events"] as? [[String: Any]] ?? [], revision: object["revision"] as? String))
        }
        if object["operation"] as? String == "transcript", let id = object["id"] as? String {
            let reply = try JSONSerialization.jsonObject(with: executeAutolith(body, context: context)) as? [String: Any] ?? [:]
            return try JSONSerialization.data(withJSONObject: messageService.decorateTranscript(reply, sessionID: id))
        }
        if object["operation"] as? String == "list" {
            var reply = try JSONSerialization.jsonObject(with: executeAutolith(body, context: context)) as? [String: Any] ?? [:]
            var sessions = reply["sessions"] as? [[String: Any]] ?? []
            for i in sessions.indices {
                if let id = sessions[i]["id"] as? String {
                    let pending = messageService.outbox.pending(sessionID: id).filter { ["queued", "preparing", "dispatching"].contains($0.state) }.count
                    let queued = max(0, sessions[i]["queued"] as? Int ?? 0)
                    let (total, overflow) = queued.addingReportingOverflow(pending)
                    sessions[i]["queued"] = overflow ? Int.max : total
                }
            }
            reply["sessions"] = sessions
            return try JSONSerialization.data(withJSONObject: reply)
        }
        if object["operation"] as? String == "browse" {
            return try JSONSerialization.data(withJSONObject: WorkspaceBrowser.listing(path: object["path"] as? String))
        }
        if object["operation"] as? String == "capabilities" {
            return try JSONSerialization.data(withJSONObject: ["pushEnabled": pushService.enabled, "eventStreamVersion": 1, "transcriptSyncVersion": 1])
        }
        if object["operation"] as? String == "activity-register" {
            try pushService.register(object, beforeMutation: { try context.check() })
            return Data("{\"ok\":true}".utf8)
        }
    }
    return try executeAutolith(body, context: context)
}

func executeAutolith(_ body: Data, context: BackendRequestContext = BackendRequestContext()) throws -> Data {
    try context.check()
    guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
          let operation = object["operation"] as? String,
          ["list", "create", "resume", "transcript", "tell", "pause", "kill", "stop-idle", "delete", "catalog"].contains(operation) else { throw BridgeError.invalid("Unsupported operation") }
    return try backend.call(JSONSerialization.data(withJSONObject: object), context: context)
}

final class Client {
    let connection: BridgeConnection
    let id = UUID()
    let context = BackendRequestContext(deadline: .now() + 65)
    var authenticated = false
    var dispatched = false
    var data = Data()
    var finished = false
    var stream: EventStream?
    func disconnected() { context.cancel(); stream?.stop(); stream = nil }
    init(_ connection: BridgeConnection) { self.connection = connection }
    func reply(_ status: Int, _ body: Data) {
        guard !finished else { return }; finished = true
        context.cancel()
        data.removeAll()
        let head = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(Data(head.utf8) + body) { _ in self.connection.cancel() }
    }
    func fail(_ status: Int, _ text: String) { reply(status, (try? JSONSerialization.data(withJSONObject: ["error": text])) ?? Data()) }
    func authenticate(_ authorization: String) -> Bool {
        if authenticated { return true }
        guard authorized(authorization) else { fail(401, "Invalid companion token"); return false }
        guard admission.authenticate(id) else { fail(503, "Too many authenticated connections"); return false }
        authenticated = true
        return true
    }
    func receive() {
        connection.receive { bytes, ended, error in
            guard !self.finished else { return }
            if let bytes { self.data.append(bytes) }
            do {
                if self.data.starts(with: Data("GET ".utf8)) {
                    if let upgrade = try WebSocketUpgrade.parse(self.data) {
                        guard self.authenticate(upgrade.authorization) else { return }
                        let headers = String(decoding: self.data.prefix(upgrade.consumedBytes), as: UTF8.self)
                        guard !headers.components(separatedBy: "\r\n").dropFirst().contains(where: { $0.lowercased().hasPrefix("origin:") }) else {
                            self.fail(403, "Browser event streams are not supported"); return
                        }
                        guard streamSlots.wait(timeout: .now()) == .success else { self.fail(503, "Too many event streams"); return }
                        self.finished = true
                        let stream = EventStream(connection: self.connection, queue: queue, executable: executable) { streamSlots.signal() }
                        self.stream = stream
                        let remainder = Data(self.data.dropFirst(upgrade.consumedBytes))
                        self.data.removeAll()
                        stream.start(response: upgrade.response, remainder: remainder)
                    } else if ended || error != nil { self.connection.cancel() }
                    else { self.receive() }
                } else if self.data.count < 4 && !ended && error == nil {
                    self.receive()
                } else {
                    if let header = try HTTPRequest.parseHeader(self.data) {
                        guard self.authenticate(header.authorization) else { return }
                    }
                    if let request = try HTTPRequest.parse(self.data) {
                        guard slots.wait(timeout: .now()) == .success else { self.fail(503, "Companion is busy"); return }
                        self.dispatched = true
                        // Reject a second request or transport failure, but allow
                        // a client to half-close its request and still read the reply.
                        self.connection.receive { bytes, _, error in
                            if error != nil || bytes?.isEmpty == false {
                                self.context.cancel()
                                self.connection.cancel()
                            }
                        }
                        let context = self.context
                        workers.async {
                            defer { slots.signal() }
                            do {
                                let response = try execute(request.body, context: context)
                                queue.async { self.reply(200, response) }
                            } catch {
                                let message = error.localizedDescription
                                queue.async { self.fail(502, message) }
                            }
                        }
                    } else if ended || error != nil { self.connection.cancel() }
                    else { self.receive() }
                }
            } catch { self.fail(400, error.localizedDescription) }
        }
    }
}
var admission = ConnectionAdmission()
var clients: [UUID: Client] = [:]
try listener.start(port: port) { connection in
    let client = Client(connection)
    if let evicted = admission.admit(client.id), let previous = clients.removeValue(forKey: evicted) {
        previous.connection.cancel()
    }
    clients[client.id] = client
    connection.onClose = {
        admission.remove(client.id)
        clients.removeValue(forKey: client.id)
        client.disconnected()
        connection.onClose = nil
    }
    client.receive()
    queue.asyncAfter(deadline: .now() + 5) { [weak client] in
        if let client, !client.finished, !client.authenticated { client.fail(408, "Authentication handshake timed out") }
    }
    queue.asyncAfter(deadline: .now() + 15) { [weak client] in
        if let client, !client.finished, !client.dispatched { client.fail(408, "Request body timed out") }
    }
    queue.asyncAfter(deadline: client.context.deadline) { [weak client] in
        if let client, !client.finished {
            client.fail(408, "Request deadline exceeded. A dispatched mutation may have run; check the conversation before retrying.")
        }
    }
}
print("Autolith companion listening on 127.0.0.1:\(listener.port ?? Int(port)). Expose with Tailscale Serve HTTPS.")
dispatchMain()
