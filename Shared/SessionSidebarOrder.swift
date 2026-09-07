import Foundation

struct SessionSection: Identifiable, Sendable {
    let id: String
    let sessions: [Session]
}

/// Derive ordering from saved activity, never from discovery or cache arrival order.
enum SessionSidebarOrder {
    static func ordered(_ sessions: [Session]) -> [Session] {
        return sessions.sorted {
            let left = recency($0), right = recency($1)
            return left == right ? $0.id < $1.id : left > right
        }
    }

    static func sections(_ sessions: [Session], grouped: Bool) -> [SessionSection] {
        let sorted = ordered(sessions)
        guard grouped else { return [SessionSection(id: "All sessions", sessions: sorted)] }
        let groups = Dictionary(grouping: sorted) {
            $0.workspace.isEmpty ? "Unknown project" : URL(fileURLWithPath: $0.workspace).standardizedFileURL.path
        }
        return groups.map { SessionSection(id: $0.key, sessions: $0.value) }.sorted {
            let left = $0.sessions.first.map(recency) ?? 0
            let right = $1.sessions.first.map(recency) ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
    }

    private static func recency(_ session: Session) -> Double {
        guard let value = session.updatedAt, value.isFinite, value > 0 else { return 0 }
        return value
    }
}
