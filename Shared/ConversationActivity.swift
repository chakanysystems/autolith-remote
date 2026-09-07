import Foundation

/// Presentation categories for recorded events, not inferred execution states.
enum ConversationActivityKind: String, CaseIterable, Identifiable {
    case thinking = "Thinking"
    case tool = "Tools"
    case rlm = "RLM"
    case job = "Jobs"
    case other = "Events"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .thinking: "brain"
        case .tool: "terminal"
        case .rlm: "point.3.connected.trianglepath.dotted"
        case .job: "square.stack.3d.up"
        case .other: "text.alignleft"
        }
    }
}

extension Event {
    var activityKind: ConversationActivityKind? {
        if role == "user" || role == "assistant" { return nil }
        if ["reasoning", "thinking"].contains(role) { return .thinking }
        // Accept dotted UI names, Lisp names, and provider-qualified tool names.
        let parts = tool.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if parts.contains("rlm") { return .rlm }
        if parts.contains("job") || parts.contains("task") { return .job }
        if !tool.isEmpty || ["tool-call", "tool-result", "web-search", "user-operation"].contains(role) { return .tool }
        return .other
    }

    var activityTitle: String {
        switch activityKind {
        case .thinking: return "Thinking"
        case .rlm: return "RLM · \(tool)"
        case .job: return "Jobs · \(tool)"
        default:
            if role == "user-operation" { return "Local Lisp / command" }
            return tool.isEmpty ? role.replacingOccurrences(of: "-", with: " ").capitalized : tool
        }
    }

    var activityPhase: String? {
        switch role {
        case "tool-call": "Call"
        case "tool-result": "Result"
        default: nil
        }
    }

    /// Keep previews bounded without copying a potentially large tool result.
    var activityPreview: String {
        String(text.prefix(240)).split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    var hasLongOutput: Bool {
        let prefix = text.prefix(601)
        return prefix.count > 600 || prefix.split(separator: "\n", maxSplits: 8, omittingEmptySubsequences: false).count > 8
    }
}

/// Use session state for progress; use live events only while their stream is connected.
struct ConversationWorkerStatus: Equatable {
    let text: String
    let isWorking: Bool
    let usesPolling: Bool
    private(set) var workers: [String] = []

    init(session: Session, events: [Event], online: Bool, connected: Bool) {
        isWorking = online && session.isRunning && session.isWorking
        usesPolling = online && session.isRunning && !connected
        guard online else { text = "Disconnected"; return }
        guard session.isRunning else { text = "Stopped"; return }
        guard connected else {
            text = session.state == "cancelling" ? "Stopping" : (isWorking ? "Working" : "Ready")
            return
        }
        guard session.isWorking else { text = "Ready"; return }

        // The v1 publisher encodes job rows as three bounded fields:
        // job ID, worker/tool name, lifecycle state. Do not display the raw row.
        workers = Array(Set(events.compactMap { event -> String? in
            guard event.role == "status", event.id.hasPrefix("job-") else { return nil }
            let fields = event.text.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, ["running", "queued"].contains(fields[2]) else { return nil }
            return String(fields[1])
        })).sorted()

        // Native rows are ordered by their last update. A completion clears the
        // matching start, including when the same tool runs again in one turn.
        var pending: [Event] = []
        for event in events where event.role == "status" && event.id.hasPrefix("live-") {
            if event.id.contains("-tool-call-started-") {
                pending.removeAll { $0.tool == event.tool }
                pending.append(event)
            } else if event.id.contains("-tool-call-completed-") {
                pending.removeAll { $0.tool == event.tool }
            }
        }
        if let tool = pending.last {
            let words = tool.tool.lowercased().split { !$0.isLetter && !$0.isNumber }
            if words.contains("rlm") {
                text = "Waiting for RLM"
            } else if words.contains("job") && words.contains("wait") {
                text = "Waiting for jobs"
            } else if words.contains("task") && words.contains("run") {
                text = "Waiting for workers"
            } else {
                text = "Running \(tool.tool)"
            }
            return
        }
        if session.state == "cancelling" {
            text = "Stopping"
        } else if session.jobs > 0 && !["active", "working", "starting"].contains(session.state) {
            text = workers.contains(where: { $0.lowercased().contains("rlm") }) ? "Waiting for RLM" : "Waiting for jobs"
        } else if session.queued > 0 && session.jobs == 0 && !["active", "working", "starting"].contains(session.state) {
            text = "Queued"
        } else {
            text = "Working"
        }
    }
}
