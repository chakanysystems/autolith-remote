import Foundation
import CoreFoundation

/// Measures continuously observed inactivity; missing or failed observations reset it.
public struct IdleSessionPolicy {
    private struct Observation { let since: TimeInterval; let revision: Double; let pid: Int }
    private var observations: [String: Observation] = [:]
    public let timeout: TimeInterval
    public init(timeout: TimeInterval) { self.timeout = timeout }
    public mutating func reset() { observations.removeAll() }
    public mutating func activity(_ id: String) { observations[id] = nil }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    public mutating func candidates(_ sessions: [[String: Any]], now: TimeInterval) -> [String] {
        guard now.isFinite, timeout.isFinite, timeout > 0 else { reset(); return [] }
        var retained: [String: Observation] = [:]
        var result: [String] = []
        let ids = sessions.compactMap { $0["id"] as? String }
        let counts = Dictionary(ids.map { ($0, 1) }, uniquingKeysWith: +)
        for session in sessions {
            guard let id = session["id"] as? String, !id.isEmpty, counts[id] == 1,
                  session["state"] as? String == "idle",
                  number(session["jobs"]) == 0, number(session["queued"]) == 0,
                  let revision = number(session["updatedAt"]), revision >= 0,
                  let rawPID = number(session["pid"]), rawPID > 0, rawPID <= Double(Int32.max),
                  rawPID.rounded(.down) == rawPID else { continue }
            let pid = Int(rawPID)
            let old = observations[id]
            let fresh = Observation(since: now, revision: revision, pid: pid)
            let observation = old?.revision == revision && old?.pid == pid && now >= (old?.since ?? now) ? old ?? fresh : fresh
            retained[id] = observation
            if now - observation.since >= timeout { result.append(id) }
        }
        observations = retained
        return result
    }
}
