import Foundation

/// Listener-queue-owned admission. Pending handshakes cannot consume authenticated slots.
public struct ConnectionAdmission {
    private let pendingLimit: Int
    private let authenticatedLimit: Int
    private var pending: [UUID] = []
    private var authenticated: Set<UUID> = []

    public init(pendingLimit: Int = 16, authenticatedLimit: Int = 32) {
        precondition(pendingLimit > 0 && authenticatedLimit > 0)
        self.pendingLimit = pendingLimit
        self.authenticatedLimit = authenticatedLimit
    }

    /// Admit a new handshake, replacing the oldest unauthenticated connection if full.
    public mutating func admit(_ id: UUID) -> UUID? {
        guard !pending.contains(id), !authenticated.contains(id) else { return nil }
        let evicted = pending.count == pendingLimit ? pending.removeFirst() : nil
        pending.append(id)
        return evicted
    }

    public mutating func authenticate(_ id: UUID) -> Bool {
        if authenticated.contains(id) { return true }
        guard authenticated.count < authenticatedLimit, let index = pending.firstIndex(of: id) else { return false }
        pending.remove(at: index)
        authenticated.insert(id)
        return true
    }

    public mutating func remove(_ id: UUID) {
        pending.removeAll { $0 == id }
        authenticated.remove(id)
    }
}
