import Foundation
import BridgeCore

/// Daemon-owned cleanup continues while every mobile client is suspended.
final class IdleSessionService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "autolith.idle-sessions", qos: .utility)
    private var policy: IdleSessionPolicy
    private var timer: DispatchSourceTimer?
    private let call: ([String: Any]) throws -> [String: Any]

    init(timeout: TimeInterval, call: @escaping ([String: Any]) throws -> [String: Any]) {
        policy = IdleSessionPolicy(timeout: timeout)
        self.call = call
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func activity(_ id: String) { queue.async { self.policy.activity(id) } }

    private func poll() {
        do {
            let reply = try call(["operation": "list"])
            guard let sessions = reply["sessions"] as? [[String: Any]] else {
                throw BridgeError.invalid("Invalid session cleanup inventory")
            }
            for id in policy.candidates(sessions, now: ProcessInfo.processInfo.systemUptime) {
                do {
                    // The session rechecks work under its input lock before stopping.
                    _ = try call(["operation": "stop-idle", "id": id])
                } catch {
                    fputs("Idle session cleanup deferred for \(id): \(error.localizedDescription)\n", stderr)
                }
                policy.activity(id)
            }
        } catch {
            policy.reset()
            fputs("Idle session cleanup inventory failed: \(error.localizedDescription)\n", stderr)
        }
    }
}
