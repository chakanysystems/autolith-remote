import Foundation

/// Measures continuously observed inactivity; missing or failed observations reset it.
public struct IdleSessionPolicy {
    private struct Observation { let since: TimeInterval; let revision: Double?; let pid: Int? }
    private var observations: [String: Observation] = [:]
    public let timeout: TimeInterval
    public init(timeout: TimeInterval) { self.timeout = timeout }
    public mutating func reset() { observations.removeAll() }
    public mutating func activity(_ id: String) { observations[id] = nil }
    public mutating func candidates(_ sessions: [[String: Any]], now: TimeInterval) -> [String] {
        var retained: [String: Observation] = [:]
        var result: [String] = []
        for session in sessions {
            guard let id = session["id"] as? String, session["state"] as? String == "idle",
                  session["jobs"] as? Int == 0, session["queued"] as? Int == 0 else { continue }
            let revision = session["updatedAt"] as? Double
            let pid = session["pid"] as? Int
            let old = observations[id]
            let fresh = Observation(since: now, revision: revision, pid: pid)
            let observation = old?.revision == revision && old?.pid == pid ? old ?? fresh : fresh
            retained[id] = observation
            if now - observation.since >= timeout { result.append(id) }
        }
        observations = retained
        return result
    }
}
