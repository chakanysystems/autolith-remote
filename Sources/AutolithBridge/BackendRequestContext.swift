import Foundation
import BridgeCore

/// One request's monotonic budget, passed explicitly through every backend call.
final class BackendRequestContext: @unchecked Sendable {
    let deadline: DispatchTime
    private let lock = NSLock()
    private var cancelled = false

    init(deadline: DispatchTime = .now() + 60) { self.deadline = deadline }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var remaining: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline.uptimeNanoseconds > now ? Double(deadline.uptimeNanoseconds - now) / 1_000_000_000 : 0
    }
    func check() throws { try whileActive {} }

    /// Linearize cancellation with a short nonblocking side effect, such as a
    /// pipe write. Never hold this lock while polling or running backend work.
    func whileActive<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw BridgeError.invalid("Backend request cancelled. Check the conversation before retrying a mutation.") }
        guard remaining > 0 else { throw BridgeError.invalid("Backend request timed out. Check the conversation before retrying a mutation.") }
        return try body()
    }
}
