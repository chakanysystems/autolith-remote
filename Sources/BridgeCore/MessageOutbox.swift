import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Durable handoffs with bounded payload/metadata storage and permanent replay tombstones.
/// Admission stops at 24 MiB, reserving 8 MiB for transitions of already admitted work.
/// Once the lifetime identity ledger fills the admission budget, new work is rejected.
/// Possibly sent handoffs are never retried automatically.
public final class MessageOutbox: @unchecked Sendable {
    public struct Message: Codable, Sendable, Equatable {
        public let id: String
        public let sessionID: String
        public let workspace: String
        public var text: String
        public let created: Double
        public var dispatchAt: Double
        public var state: String
        public var completedAt: Double?
        public var attempts: Int? = nil
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
    static let byteLimit = 32 * 1024 * 1024
    static let admissionByteLimit = 24 * 1024 * 1024
    static let readLimit = 100_000

    private static func isTerminal(_ message: Message) -> Bool {
        message.state == "sent" || message.state == "unsent"
    }
    private let lock = NSRecursiveLock()
    private let file: URL
    private var storage: Storage
    private var lockFile: Int32
    var persist: (Data, URL) throws -> Void = { try DurableJSONFile.write($0, to: $1) }
    // Lowered by focused capacity tests; production uses the fixed admission budget.
    var admissionByteBudget = MessageOutbox.admissionByteLimit
    private var needsDurabilityConfirmation = false

    public init(file: URL, now: Double = Date().timeIntervalSince1970) throws {
        self.file = file
        let descriptor = try DurableJSONFile.openLock(at: URL(fileURLWithPath: file.path + ".lock"))
        lockFile = descriptor
        storage = Storage()
        do {
            if let data = try DurableJSONFile.read(at: file, maximumBytes: Self.byteLimit) {
                storage = try JSONDecoder().decode(Storage.self, from: data)
            }
            try recoverInFlight(now: now)
            try retireTerminalMessages(now: now)
            try save()
        } catch { close(descriptor); lockFile = -1; throw error }
    }

    deinit { if lockFile >= 0 { close(lockFile) } }

    private func save() throws {
        let data = try JSONEncoder().encode(storage)
        guard data.count <= Self.byteLimit else { throw BridgeError.invalid("Outbox byte budget exhausted.") }
        try persist(data, file)
    }

    private func checkAdmission() throws {
        guard storage.read.count <= Self.readLimit,
              try JSONEncoder().encode(storage).count <= admissionByteBudget else {
            throw BridgeError.invalid("Outbox storage is full. Abandon unresolved work or retire completed payloads before adding more. Lifetime replay identities cannot be removed.")
        }
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
    /// Check a request deadline after acquiring the mutation lock, before changing state.
    public func withMutationPrecondition<T>(_ check: () throws -> Void, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try check()
        return try body()
    }
    private func change<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if needsDurabilityConfirmation {
            try save()
            needsDurabilityConfirmation = false
        }
        let before = storage
        do { let result = try operation(); if storage != before { try save() }; return result }
        catch let error as DurableJSONFile.CommitError {
            needsDurabilityConfirmation = true
            throw error
        }
        catch { storage = before; throw error }
    }

    /// Call only when no dispatcher is active, e.g. startup or between serial dispatch ticks.
    /// Recover transitions whose failure could not be recorded during the previous tick.
    public func recoverInFlight(now: Double = Date().timeIntervalSince1970) throws {
        try change {
            guard now.isFinite else { throw BridgeError.invalid("Invalid outbox time.") }
            for id in storage.messages.keys {
                if storage.messages[id]?.state == "preparing" {
                    var message = storage.messages[id]!
                    let attempts = min(4, max(0, message.attempts ?? 0)) + 1
                    message.attempts = attempts
                    message.state = attempts < 5 ? "queued" : "failed"
                    message.dispatchAt = now + min(300, 15 * pow(2, Double(attempts)))
                    storage.messages[id] = message
                } else if storage.messages[id]?.state == "dispatching" {
                    storage.messages[id]?.state = "uncertain"
                }
            }
        }
    }
    public func enqueue(id: String, sessionID: String, workspace: String, text: String, now: Double = Date().timeIntervalSince1970, scheduled: Double? = nil) throws -> Message {
        try change {
            guard let requestID = UUID(uuidString: id), now.isFinite,
                  !sessionID.isEmpty, sessionID.utf8.count <= 4096,
                  workspace.hasPrefix("/"), workspace.utf8.count <= 4096,
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
            try checkAdmission()
            return value
        }
    }

    public func message(_ id: String) -> Message? {
        lock.lock(); defer { lock.unlock() }
        return storage.messages[id]
    }

    public func pending(sessionID: String) -> [Message] {
        lock.lock(); defer { lock.unlock() }
        return storage.messages.values.filter { $0.sessionID == sessionID && !Self.isTerminal($0) }.sorted { $0.created < $1.created }
    }

    public func edit(_ id: String, text: String, now: Double = Date().timeIntervalSince1970) throws -> Message {
        try change {
            guard var message = storage.messages[id], message.state == "queued", now < message.dispatchAt else {
                throw BridgeError.invalid("The message has already entered execution and cannot be edited. Send a follow-up instead.")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000 else { throw BridgeError.invalid("Provide a nonempty message under 100 KB.") }
            message.text = text; storage.messages[id] = message
            try checkAdmission()
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
        try setRead([id], value: value)
    }

    public func setRead(_ ids: [String], value: Bool) throws {
        try change {
            guard ids.count <= 100, ids.allSatisfy({ $0.utf8.count <= 8192 }) else { throw BridgeError.invalid("Read receipt metadata exceeds its budget.") }
            let addsMetadata = ids.contains { storage.read[$0] == nil }
            for id in ids { storage.read[id] = value }
            if addsMetadata { try checkAdmission() }
        }
    }

    /// Validate and record an outbox receipt under the same lock as payload retirement.
    public func setMessageRead(_ id: String, sessionID: String, value: Bool) throws {
        try change {
            guard let message = storage.messages[id], message.sessionID == sessionID, message.state != "unsent" else {
                throw BridgeError.invalid("Message no longer exists.")
            }
            let key = sessionID + "#outbox-" + id
            let addsMetadata = storage.read[key] == nil
            storage.read[key] = value
            if addsMetadata { try checkAdmission() }
        }
    }

    /// Shared across clients of this companion. Explicit overrides win over role defaults.
    public func isRead(_ id: String, role: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.read[id] ?? (role != "assistant")
    }

    public func claim(now: Double = Date().timeIntervalSince1970, preparing: Bool = false) throws -> Message? {
        try change {
            try retireTerminalMessages(now: now)
            guard var message = storage.messages.values.filter({ $0.state == "queued" && $0.dispatchAt <= now }).sorted(by: { $0.dispatchAt < $1.dispatchAt }).first else { return nil }
            message.state = preparing ? "preparing" : "dispatching"; storage.messages[message.id] = message
            return message
        }
    }

    /// Persist the ambiguity boundary immediately before calling tell.
    public func beginHandoff(_ id: String) throws {
        try change {
            guard storage.messages[id]?.state == "preparing" else { throw BridgeError.invalid("Message is not preparing.") }
            storage.messages[id]?.state = "dispatching"
        }
    }

    public func preparationFailed(_ id: String, now: Double = Date().timeIntervalSince1970) throws {
        try change {
            guard now.isFinite, var message = storage.messages[id], message.state == "preparing" else { throw BridgeError.invalid("Message is not preparing.") }
            let attempts = min(4, max(0, message.attempts ?? 0)) + 1
            message.attempts = attempts
            message.state = attempts < 5 ? "queued" : "failed"
            message.dispatchAt = now + min(300, 15 * pow(2, Double(attempts)))
            storage.messages[id] = message
        }
    }

    /// Explicit retry is only safe after a known failure before tell was invoked.
    public func retry(_ id: String, now: Double = Date().timeIntervalSince1970) throws -> Message {
        try change {
            guard now.isFinite, var message = storage.messages[id], message.state == "failed" else { throw BridgeError.invalid("Only a known pre-handoff failure can be retried.") }
            message.state = "queued"; message.attempts = 0; message.dispatchAt = now + 30
            storage.messages[id] = message
            return message
        }
    }

    /// Forget a payload without authorizing replay of its identity or undoing delivery.
    public func abandon(_ id: String) throws {
        try change {
            guard let uuid = UUID(uuidString: id) else { throw BridgeError.invalid("Invalid request ID.") }
            if storage.retiredIDs.contains(uuid) { return }
            guard let message = storage.messages[id], !["preparing", "dispatching"].contains(message.state) else { throw BridgeError.invalid("Cannot abandon an active handoff.") }
            storage.retiredIDs.insert(uuid)
            storage.messages.removeValue(forKey: id)
            storage.read.removeValue(forKey: message.sessionID + "#outbox-" + id)
        }
    }

    public func receipt(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let uuid = UUID(uuidString: id) else { return nil }
        if storage.retiredIDs.contains(uuid) { return "retired" }
        return (storage.messages[id] ?? storage.messages.values.first { UUID(uuidString: $0.id) == uuid })?.state
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
