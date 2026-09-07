import AppIntents
import Foundation

struct AutolithStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Autolith progress"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Workspace") var workspace: AutolithWorkspaceEntity?
    static var parameterSummary: some ParameterSummary { Summary("Check Autolith progress in \(\.$workspace)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriInvocation.record("Check progress")
        let (connection, sessions) = try await SiriSessionService.sessions()
        if let workspace { try SiriSessionService.requireHost(workspace.host, connection: connection) }
        let path = workspace?.path ?? SiriWorkspaceConfiguration.load(host: connection.host).defaultPath
        let matching = sessions.filter { path == nil || $0.workspace == path }
        let working = matching.filter(\.isWorking)
        let scope = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "all workspaces"
        let message = "In \(scope), \(working.count) sessions are working. \(working.reduce(0) { $0 + $1.jobs }) tasks are running and \(working.reduce(0) { $0 + $1.queued }) prompts are queued."
        return .result(dialog: "\(message)")
    }
}

struct StopAutolithTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop an Autolith task"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Workspace") var workspace: AutolithWorkspaceEntity?
    @Parameter(title: "Session") var session: AutolithSessionEntity?
    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$session) in \(\.$workspace)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriInvocation.record("Stop task")
        let (connection, sessions) = try await SiriSessionService.sessions()
        if let workspace { try SiriSessionService.requireHost(workspace.host, connection: connection) }
        if let session { try SiriSessionService.requireHost(session.host, connection: connection) }
        let path = workspace?.path ?? (session == nil ? SiriWorkspaceConfiguration.load(host: connection.host).defaultPath : nil)
        let candidates = sessions.filter { $0.isWorking && (path == nil || $0.workspace == path) && (session == nil || $0.id == session?.sessionID) }
        guard !candidates.isEmpty else { return .result(dialog: "No matching task is currently working.") }
        let selected: AutolithSessionEntity
        if candidates.count == 1 { selected = AutolithSessionEntity(session: candidates[0], host: connection.host) }
        else { selected = try await $session.requestDisambiguation(among: candidates.map { AutolithSessionEntity(session: $0, host: connection.host) }, dialog: "Which task should I stop?") }
        try await requestConfirmation(result: .result(dialog: "Stop \(selected.title) in \(selected.workspace)?"))
        _ = try await connection.call(["operation": "kill", "id": selected.sessionID])
        return .result(dialog: "Sent the stop request for \(selected.title).")
    }
}
