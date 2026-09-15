import Foundation
import BridgeCore

/// Daemon-owned cleanup continues while every mobile client is suspended.
final class IdleSessionService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "autolith.idle-sessions", qos: .utility)
    private var policy: IdleSessionPolicy
    private let lock = NSLock()
    private var recentActivity: Set<String> = []
    private var timer: DispatchSourceTimer?
    private let call: ([String: Any]) throws -> [String: Any]
    private let clock: () -> TimeInterval

    init(timeout: TimeInterval, startTimer: Bool = true,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         call: @escaping ([String: Any]) throws -> [String: Any]) {
        policy = IdleSessionPolicy(timeout: timeout)
        self.call = call
        self.clock = clock
        guard startTimer else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    /// Record activity immediately, not behind a blocking inventory RPC.
    func activity(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        policy.activity(id)
        recentActivity.insert(id)
    }

    // Called serially by the timer; internal for deterministic service tests.
    func poll(now: TimeInterval? = nil) {
        lock.lock(); recentActivity.removeAll(); lock.unlock()
        do {
            let reply = try call(["operation": "list"])
            guard let sessions = reply["sessions"] as? [[String: Any]] else {
                throw BridgeError.invalid("Invalid session cleanup inventory")
            }
            lock.lock()
            // Inventory may block: start newly observed idle intervals only now.
            let candidates = policy.candidates(sessions, now: now ?? clock())
            for id in recentActivity { policy.activity(id) }
            lock.unlock()
            for id in candidates {
                lock.lock()
                let invalidated = recentActivity.contains(id)
                lock.unlock()
                if invalidated { continue }
                do {
                    // RPC v1 only rechecks busy state. Closing the remaining
                    // cross-process race requires conditional stop by revision/PID.
                    _ = try call(["operation": "stop-idle", "id": id])
                } catch {
                    fputs("Idle session cleanup deferred for \(id): \(error.localizedDescription)\n", stderr)
                }
                activity(id)
            }
        } catch {
            lock.lock(); policy.reset(); lock.unlock()
            fputs("Idle session cleanup inventory failed: \(error.localizedDescription)\n", stderr)
        }
    }
}
