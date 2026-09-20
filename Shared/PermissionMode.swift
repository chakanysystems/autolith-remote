/// Backend status names differ from the arguments accepted by the permissions form and session creation.
enum PermissionMode: String, CaseIterable, Identifiable, Sendable {
    case ask
    case auto
    case sandboxed
    case fullAccess = "full-access"

    var id: String { rawValue }
    var argument: String {
        switch self {
        case .ask: "ask"
        case .auto: "auto"
        case .sandboxed: "sandbox"
        case .fullAccess: "full"
        }
    }
    var title: String {
        switch self {
        case .ask: "Ask on Computer"
        case .auto: "Automatic"
        case .sandboxed: "Sandboxed"
        case .fullAccess: "Full Access"
        }
    }
    var explanation: String {
        switch self {
        case .ask: "Approve protected commands in a controlling terminal on your computer."
        case .auto: "Let Autolith’s permission classifier choose sandboxed access, full access, or denial for each command."
        case .sandboxed: "Run commands in the workspace sandbox with an isolated network and a read-only host."
        case .fullAccess: "Run commands with your computer’s full user privileges, without approval prompts."
        }
    }
}
