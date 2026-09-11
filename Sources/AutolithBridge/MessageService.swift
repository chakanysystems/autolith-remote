import Foundation
import BridgeCore

final class MessageService: @unchecked Sendable {
    let outbox: MessageOutbox
    private let call: ([String: Any]) throws -> [String: Any]
    private let queue = DispatchQueue(label: "autolith.messages")
    private var timer: DispatchSourceTimer?

    init(file: URL, startTimer: Bool = true, call: @escaping ([String: Any]) throws -> [String: Any]) throws {
        outbox = try MessageOutbox(file: file)
        self.call = call
        guard startTimer else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.dispatchNext() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    private func field(_ key: String, _ object: [String: Any]) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else { throw BridgeError.invalid("Missing \(key).") }
        return value
    }

    func handle(_ object: [String: Any], request: (([String: Any]) throws -> [String: Any])? = nil,
                beforeMutation: (() throws -> Void)? = nil) throws -> [String: Any]? {
        let call = request ?? self.call
        func mutate<T>(_ body: () throws -> T) throws -> T {
            try outbox.withMutationPrecondition({ try beforeMutation?() }, body)
        }
        switch object["operation"] as? String {
        case "messages-read":
            let sessionID = try field("id", object)
            guard let requested = object["eventIDs"] as? [String], requested.count <= 100 else { throw BridgeError.invalid("Request at most 100 read receipts.") }
            let wanted = Set(requested)
            let transcript = try call(["operation": "transcript", "id": sessionID, "after": 0])
            let events = transcript["events"] as? [[String: Any]] ?? []
            let valid = events.compactMap { event -> String? in
                guard let id = event["id"] as? String, wanted.contains(id), ["user", "assistant"].contains(event["role"] as? String ?? "") else { return nil }
                return id
            }
            try mutate { try outbox.setRead(valid.map { sessionID + "#" + $0 }, value: true) }
            return ["ok": true, "readIDs": valid]
        case "message-events":
            let sessionID = try field("id", object)
            guard let identifiers = object["eventIDs"] as? [String], identifiers.count <= 100 else {
                throw BridgeError.invalid("Request at most 100 message IDs.")
            }
            let wanted = Set(identifiers)
            var events: [[String: Any]] = []
            let sequences = wanted.filter { !$0.hasPrefix("outbox-") }.compactMap(Int.init).filter { $0 >= 0 }
            if let first = sequences.min() {
                let transcript = try call(["operation": "transcript", "id": sessionID, "after": max(0, first - 1)])
                events = (transcript["events"] as? [[String: Any]] ?? []).filter {
                    wanted.contains($0["id"] as? String ?? "") && ["user", "assistant"].contains($0["role"] as? String ?? "")
                }
                for i in events.indices {
                    if let id = events[i]["id"] as? String {
                        events[i]["isRead"] = outbox.isRead(sessionID + "#" + id, role: events[i]["role"] as? String ?? "")
                    }
                }
            }
            for id in wanted where id.hasPrefix("outbox-") {
                if let message = outbox.message(String(id.dropFirst(7))), message.sessionID == sessionID, message.state != "unsent" {
                    events.append(event(message))
                }
            }
            return ["events": events]
        case "message-send":
            let sessionID = try field("id", object)
            let sessions = try call(["operation": "list"])["sessions"] as? [[String: Any]] ?? []
            guard let session = sessions.first(where: { $0["id"] as? String == sessionID }), let workspace = session["workspace"] as? String else { throw BridgeError.invalid("Conversation no longer exists.") }
            let message = try mutate { try outbox.enqueue(id: field("requestID", object), sessionID: sessionID, workspace: workspace, text: field("text", object), scheduled: object["scheduledDate"] as? Double) }
            return ["events": [event(message)], "id": "outbox-" + message.id]
        case "message-receipt":
            let requestID = try field("requestID", object)
            guard UUID(uuidString: requestID) != nil else { throw BridgeError.invalid("Invalid request ID.") }
            return ["requestID": requestID, "state": outbox.receipt(requestID) ?? "missing"]
        case "message-get", "message-edit", "message-unsend", "message-retry", "message-abandon":
            let eventID = try field("eventID", object), sessionID = try field("id", object)
            if object["operation"] as? String == "message-get" {
                guard eventID.hasPrefix("outbox-"), let message = outbox.message(String(eventID.dropFirst(7))),
                      message.sessionID == sessionID, message.state != "unsent" else { return ["events": []] }
                return ["events": [event(message)]]
            }
            guard eventID.hasPrefix("outbox-"), let existing = outbox.message(String(eventID.dropFirst(7))), existing.sessionID == sessionID else { throw BridgeError.invalid("That message cannot be edited or unsent; it is already part of the executed transcript.") }
            let id = existing.id
            if object["operation"] as? String == "message-abandon" { try mutate { try outbox.abandon(id) }; return ["ok": true, "state": "retired"] }
            if object["operation"] as? String == "message-retry" { return ["events": [event(try mutate { try outbox.retry(id) })]] }
            if object["operation"] as? String == "message-edit" {
                return ["events": [event(try mutate { try outbox.edit(id, text: field("text", object)) })]]
            }
            if object["operation"] as? String == "message-unsend" { try mutate { try outbox.unsend(id) }; return ["ok": true] }
            return ["events": existing.state == "unsent" ? [] : [event(existing)]]
        case "message-read":
            let sessionID = try field("id", object), eventID = try field("eventID", object)
            guard let read = object["isRead"] as? Bool else { throw BridgeError.invalid("Missing read state.") }
            if eventID.hasPrefix("outbox-") {
                try mutate { try outbox.setMessageRead(String(eventID.dropFirst(7)), sessionID: sessionID, value: read) }
            } else {
                let events = try call(["operation": "transcript", "id": sessionID, "after": 0])["events"] as? [[String: Any]] ?? []
                guard events.contains(where: { $0["id"] as? String == eventID && ["user", "assistant"].contains($0["role"] as? String ?? "") }) else { throw BridgeError.invalid("Message no longer exists.") }
                try mutate { try outbox.setRead(sessionID + "#" + eventID, value: read) }
            }
            return ["ok": true]
        default: return nil
        }
    }

    func decorateTranscript(_ object: [String: Any], sessionID: String) -> [String: Any] {
        var result = object
        var events = object["events"] as? [[String: Any]] ?? []
        for i in events.indices {
            if let id = events[i]["id"] as? String {
                events[i]["isRead"] = outbox.isRead(sessionID + "#" + id, role: events[i]["role"] as? String ?? "")
            }
        }
        events += outbox.pending(sessionID: sessionID).map(event)
        result["events"] = events
        return result
    }

    private func event(_ message: MessageOutbox.Message) -> [String: Any] {
        let id = "outbox-" + message.id
        return ["id": id, "role": "user", "tool": "", "text": message.text, "timestamp": message.created,
                "deliveryState": message.state, "dispatchAt": message.dispatchAt,
                "isRead": outbox.isRead(message.sessionID + "#" + id, role: "user")]
    }

    private let dispatchLock = NSLock()
    func dispatchNext(now: Double = Date().timeIntervalSince1970) {
        dispatchLock.lock(); defer { dispatchLock.unlock() }
        do {
            try outbox.recoverInFlight(now: now)
            guard let message = try outbox.claim(now: now, preparing: true) else { return }
            do {
                let sessions = try call(["operation": "list"])["sessions"] as? [[String: Any]] ?? []
                guard let session = sessions.first(where: { $0["id"] as? String == message.sessionID }) else { throw BridgeError.invalid("Conversation no longer exists.") }
                if session["state"] as? String == "stopped" {
                    let resumed = try call(["operation": "resume", "id": message.sessionID, "workspace": message.workspace, "permissions": "ask"])
                    guard resumed["id"] as? String == message.sessionID else { throw BridgeError.invalid("Resume changed the conversation ID.") }
                }
                try outbox.beginHandoff(message.id)
                _ = try call(["operation": "tell", "id": message.sessionID, "message": "Question from Siri:\n" + message.text])
                try outbox.finish(message.id, delivered: true, now: now)
            } catch {
                if outbox.message(message.id)?.state == "preparing" {
                    try outbox.preparationFailed(message.id, now: now)
                    fputs("Message preparation failed; retry is bounded and delayed.\n", stderr)
                } else if outbox.message(message.id)?.state == "dispatching" {
                    try outbox.finish(message.id, delivered: false, now: now)
                    fputs("Message delivery is uncertain. Check its conversation before abandoning the receipt.\n", stderr)
                }
            }
        } catch { fputs("Message outbox could not persist a transition.\n", stderr) }
    }
}
