import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A durable handoff queue. A crashed handoff is uncertain and is never replayed automatically.
/// Only queued, dispatching, uncertain, and unknown states count against the 10,000-work limit.
/// Keep at most 1,000 sent/unsent payloads, for at most 30 days after completion. Legacy
/// terminal records use creation time. Retire payloads on startup and queue transitions.
/// Retired UUIDs are durable, permanent tombstones: duplicate rejection has no expiry.
/// UUIDv4 requests carry no trustworthy age, so deleting their tombstones would allow replay.
/// The small identity ledger grows with lifetime traffic; full payload retention is bounded.
/// Transcript read overrides persist until explicitly changed. Retiring an outbox payload
/// removes only its own read override, because that event can no longer be fetched.
public final class MessageOutbox: @unchecked Sendable {
    public struct Message: Codable, Sendable, Equatable {
        public let id: String
        public let sessionID: String
        public let workspace: String
        public var text: String
        public let created: Double
        public let dispatchAt: Double
        public var state: String
        public var completedAt: Double?
    }
    private struct Storage: Codable, Equatable {
        var messages: [String: Message] = [:]
        var read: [String: Bool] = [:]
        var retiredIDs: Set<UUID> = []

        private enum CodingKeys: String, CodingKey { case messages, read, retiredIDs }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            messages = try values.decode([String: Message].self, forKey: .messages)
            read = try values.decodeIfPresent([String: Bool].self, forKey: .read) ?? [:]
            retiredIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .retiredIDs) ?? []
        }
    }
    static let pendingLimit = 10_000
    static let terminalLimit = 1_000
    static let terminalLifetime: Double = 30 * 24 * 60 * 60

    private static func isTerminal(_ message: Message) -> Bool {
        message.state == "sent" || message.state == "unsent"
    }
    private let lock = NSLock()
    private let file: URL
    private var storage: Storage
    private let lockFile: Int32

    public init(file: URL, now: Double = Date().timeIntervalSince1970) throws {
        self.file = file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(file.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BridgeError.invalid("Could not open the outbox lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw BridgeError.invalid("Another companion owns the message outbox.")
        }
        lockFile = descriptor
        storage = Storage()
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                storage = try JSONDecoder().decode(Storage.self, from: Data(contentsOf: file))
            }
            for id in storage.messages.keys where storage.messages[id]?.state == "dispatching" {
                storage.messages[id]?.state = "uncertain"
            }
            try retireTerminalMessages(now: now)
            try save()
        } catch { close(descriptor); throw error }
    }

    deinit { close(lockFile) }

    private func save() throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(storage).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func retireTerminalMessages(now: Double) throws {
        guard now.isFinite else { throw BridgeError.invalid("Invalid outbox time.") }
        let terminal = storage.messages.values.filter(Self.isTerminal).sorted {
            let left = $0.completedAt ?? $0.created, right = $1.completedAt ?? $1.created
            return left == right ? $0.id < $1.id : left > right
        }
        for (index, message) in terminal.enumerated()
        where index >= Self.terminalLimit || (message.completedAt ?? message.created) <= now - Self.terminalLifetime {
            // Persist the identity and payload removal together in the same atomic write.
            guard let id = UUID(uuidString: message.id) else {
                throw BridgeError.invalid("Cannot retire an outbox record with an invalid request ID.")
            }
            storage.retiredIDs.insert(id)
            storage.messages.removeValue(forKey: message.id)
            storage.read.removeValue(forKey: message.sessionID + "#outbox-" + message.id)
        }
    }
    private func change<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let before = storage
        do { let result = try operation(); if storage != before { try save() }; return result }
        catch { storage = before; throw error }
    }

    public func enqueue(id: String, sessionID: String, workspace: String, text: String, now: Double = Date().timeIntervalSince1970, scheduled: Double? = nil) throws -> Message {
        try change {
            guard let requestID = UUID(uuidString: id), now.isFinite,
                  !sessionID.isEmpty, workspace.hasPrefix("/"),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000 else {
                throw BridgeError.invalid("Invalid message, workspace, or delivery date.")
            }
            if storage.retiredIDs.contains(requestID) {
                throw BridgeError.invalid("This message ID was already used and its receipt has expired. Check the conversation before sending again.")
            }
            // Treat UUID spelling changes as the same request, including in legacy stores.
            if let existing = storage.messages[id] ?? storage.messages.values.first(where: { UUID(uuidString: $0.id) == requestID }) {
                guard existing.sessionID == sessionID, existing.workspace == workspace, existing.text == text else {
                    throw BridgeError.invalid("This message ID was already used.")
                }
                return existing
            }
            guard scheduled == nil || (scheduled!.isFinite && scheduled! >= now) else {
                throw BridgeError.invalid("Invalid delivery date.")
            }
            guard storage.messages.values.filter({ !Self.isTerminal($0) }).count < Self.pendingLimit else {
                throw BridgeError.invalid("The message outbox has 10,000 unresolved messages. Resolve pending work before sending more.")
            }
            let value = Message(id: id, sessionID: sessionID, workspace: workspace, text: text, created: now,
                                dispatchAt: max(now + 15, scheduled ?? now), state: "queued")
            storage.messages[id] = value
            try retireTerminalMessages(now: now)
            return value
        }
    }

    public func message(_ id: String) -> Message? {
        lock.lock(); defer { lock.unlock() }
        return storage.messages[id]
    }

    public func pending(sessionID: String) -> [Message] {
        lock.lock(); defer { lock.unlock() }
        return storage.messages.values.filter { $0.sessionID == sessionID && ["queued", "dispatching", "uncertain"].contains($0.state) }.sorted { $0.created < $1.created }
    }

    public func edit(_ id: String, text: String, now: Double = Date().timeIntervalSince1970) throws -> Message {
        try change {
            guard var message = storage.messages[id], message.state == "queued", now < message.dispatchAt else {
                throw BridgeError.invalid("The message has already entered execution and cannot be edited. Send a follow-up instead.")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000 else { throw BridgeError.invalid("Provide a nonempty message under 100 KB.") }
            message.text = text; storage.messages[id] = message
            return message
        }
    }

    public func unsend(_ id: String, now: Double = Date().timeIntervalSince1970) throws {
        try change {
            if storage.messages[id]?.state == "unsent" { return }
            guard var message = storage.messages[id], message.state == "queued", now < message.dispatchAt else {
                throw BridgeError.invalid("The message has already entered execution and cannot be unsent. Stopping work does not undo tools that ran.")
            }
            message.state = "unsent"; storage.messages[id] = message
            storage.messages[id]?.completedAt = now
            try retireTerminalMessages(now: now)
        }
    }

    public func setRead(_ id: String, value: Bool) throws {
        try change { storage.read[id] = value }
    }

    public func setRead(_ ids: [String], value: Bool) throws {
        try change { for id in ids { storage.read[id] = value } }
    }

    /// Validate and record an outbox receipt under the same lock as payload retirement.
    public func setMessageRead(_ id: String, sessionID: String, value: Bool) throws {
        try change {
            guard let message = storage.messages[id], message.sessionID == sessionID, message.state != "unsent" else {
                throw BridgeError.invalid("Message no longer exists.")
            }
            storage.read[sessionID + "#outbox-" + id] = value
        }
    }

    /// Shared across clients of this companion. Explicit overrides win over role defaults.
    public func isRead(_ id: String, role: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.read[id] ?? (role != "assistant")
    }

    public func claim(now: Double = Date().timeIntervalSince1970) throws -> Message? {
        try change {
            try retireTerminalMessages(now: now)
            guard var message = storage.messages.values.filter({ $0.state == "queued" && $0.dispatchAt <= now }).sorted(by: { $0.dispatchAt < $1.dispatchAt }).first else { return nil }
            message.state = "dispatching"; storage.messages[message.id] = message
            return message
        }
    }

    public func finish(_ id: String, delivered: Bool, now: Double = Date().timeIntervalSince1970) throws {
        try change {
            guard storage.messages[id]?.state == "dispatching" else { throw BridgeError.invalid("Message is not being dispatched.") }
            storage.messages[id]?.state = delivered ? "sent" : "uncertain"
            if delivered { storage.messages[id]?.completedAt = now }
            try retireTerminalMessages(now: now)
        }
    }
}
