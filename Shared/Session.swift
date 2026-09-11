import Foundation

struct Session: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let state: String
    let workspace: String
    let model: String
    let permissions: String
    let queued: Int
    let jobs: Int
    var updatedAt: Double?
    var effort: String? = nil
    var supportedEfforts: [String]? = nil
    var isRunning: Bool { state != "stopped" }
    var isWorking: Bool { ["active", "working", "starting", "cancelling"].contains(state) || jobs > 0 || queued > 0 }

    /// Stream packets can omit saved recency and model metadata. Retain the
    /// timestamp for the same session and effort metadata for the same model.
    func mergingStreamStatus(_ update: Session) -> Session {
        guard id == update.id else { return update }
        var result = update
        if update.updatedAt == nil { result.updatedAt = updatedAt }
        if model == update.model, update.supportedEfforts == nil {
            result.supportedEfforts = supportedEfforts
            result.effort = update.effort ?? effort
        }
        return result
    }

    func commandForEffort(_ value: String) -> String? {
        guard isRunning, !value.isEmpty, supportedEfforts?.contains(value) == true else { return nil }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "/effort \"\(escaped)\""
    }
}

public struct WorkSummary: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let state: String
    }
    public let sessions: Int
    public let tasks: Int
    public let queued: Int
    public let items: [Item]

    /// Wire counters are untrusted. Clamp negatives and saturate instead of trapping.
    static func addingCounter(_ total: Int, _ value: Int) -> Int {
        let (sum, overflow) = max(0, total).addingReportingOverflow(max(0, value))
        return overflow ? Int.max : sum
    }

    public var finished: WorkSummary {
        WorkSummary(sessions: 0, tasks: 0, queued: 0,
                    items: items.map { Item(id: $0.id, title: $0.title, state: "idle") })
    }

    public static func decodeSessions(_ data: Data) throws -> WorkSummary {
        struct Envelope: Decodable { let sessions: [Session] }
        return from(try JSONDecoder().decode(Envelope.self, from: data).sessions)
    }
    static func from(_ sessions: [Session]) -> WorkSummary {
        let working = sessions.filter { $0.isRunning && $0.isWorking }.sorted {
            let left = $0.updatedAt ?? 0, right = $1.updatedAt ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
        return WorkSummary(sessions: working.count,
                           tasks: working.reduce(0) { addingCounter($0, $1.jobs) },
                           queued: working.reduce(0) { addingCounter($0, $1.queued) },
                           items: working.prefix(3).map { Item(id: $0.id, title: String(decoding: $0.title.utf8.prefix(160), as: UTF8.self), state: $0.state) })
    }
}
