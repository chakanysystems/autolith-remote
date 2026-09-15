import AppIntents
import Foundation

struct AskAutolithIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Autolith"
    static var description = IntentDescription("Send a question to a new session in a known workspace. Work continues in the background after this action finishes.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Workspace", requestValueDialog: "Which computer workspace should I use?") var workspace: AutolithWorkspaceEntity?
    @Parameter(title: "Question") var question: String?
    static var parameterSummary: some ParameterSummary { Summary("Ask Autolith \(\.$question) in \(\.$workspace)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<AutolithSessionEntity> & ProvidesDialog {
        SiriInvocation.record("New question: started")
        let input: String
        if let question { input = question }
        else {
            SiriInvocation.record("New question: waiting for dictation")
            input = try await $question.requestValue("Tell me the question to send to Autolith.")
        }
        SiriInvocation.record("New question: dictation received")
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = try SiriContent.question(input)
        let connection = try SiriSessionService.connected()
        let choices = try await AutolithWorkspaceQuery().suggestedEntities()
        guard !choices.isEmpty else { throw connection.failure("Choose a default workspace in Autolith Settings, or create a session first.") }
        let selected: AutolithWorkspaceEntity
        if let workspace {
            try SiriSessionService.requireHost(workspace.host, connection: connection)
            guard choices.contains(where: { $0.id == workspace.id }) else { throw connection.failure("That workspace is no longer available.") }
            let configuration = SiriWorkspaceConfiguration.load(host: connection.host)
            let namedPaths = SiriWorkspaceRouting.candidates(request: input, paths: choices.map(\.path), configuration: configuration)
            if SiriWorkspaceRouting.hasUnresolvedReference(input), namedPaths != [workspace.path] {
                try await requestConfirmation(result: .result(dialog: "Your request may name a different workspace. Send it to \(workspace.path)?"))
            }
            selected = workspace
        } else {
            let configuration = SiriWorkspaceConfiguration.load(host: connection.host)
            let paths = SiriWorkspaceRouting.candidates(request: input, paths: choices.map(\.path), configuration: configuration)
            let matches = choices.filter { paths.contains($0.path) }
            if matches.count == 1 { selected = matches[0] }
            else if matches.isEmpty, !SiriWorkspaceRouting.hasUnresolvedReference(input),
                    let preferred = choices.first(where: { $0.path == configuration.defaultPath }) { selected = preferred }
            else { selected = try await $workspace.requestDisambiguation(among: matches.isEmpty ? choices : matches, dialog: "Which workspace should run this request?") }
        }
        guard let id = try await connection.call(["operation": "create", "workspace": selected.path, "permissions": "ask"]).id else {
            throw connection.failure("The computer did not return a session identifier.")
        }
        do {
            _ = try await connection.call(["operation": "tell", "id": id, "message": message])
        } catch {
            throw connection.failure("Created session \(id), but could not confirm delivery of the question. Check that session in Autolith before sending again. \(error.localizedDescription)")
        }
        SiriConversationMemory.sent(id: id, host: connection.host)
        SiriInvocation.record("New question: sent")
        let session = Session(id: id, title: String(text.prefix(100)), state: "starting", workspace: selected.path, model: "", permissions: "ask", queued: 1, jobs: 0, updatedAt: Date().timeIntervalSince1970)
        if #available(iOS 27.0, macOS 27.0, *) {
            await AutolithConversationContext.remember(AutolithConversationEntity(session: session, host: connection.host, events: []))
        }
        return .result(value: AutolithSessionEntity(session: session, host: connection.host), dialog: "Sent to Autolith. Ask me to read your latest Autolith answer later.")
    }
}

struct ReadAutolithAnswerIntent: AppIntent {
    static var title: LocalizedStringResource = "Read latest Autolith answer"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Session") var session: AutolithSessionEntity?
    @Parameter(title: "Workspace") var workspace: AutolithWorkspaceEntity?
    static var parameterSummary: some ParameterSummary { Summary("Read the answer from \(\.$session) in \(\.$workspace)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        SiriInvocation.record("Read answer")
        let connection = try SiriSessionService.connected()
        let id: String
        if let session {
            try SiriSessionService.requireHost(session.host, connection: connection)
            id = session.sessionID
        } else if let workspace {
            try SiriSessionService.requireHost(workspace.host, connection: connection)
            let sessions = try await connection.call(["operation": "list"]).sessions ?? []
            guard let latest = sessions.filter({ $0.workspace == workspace.path }).max(by: { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }) else {
                throw connection.failure("There are no sessions in that workspace.")
            }
            id = latest.id
        } else {
            guard let latest = SiriConversationMemory.identifier(host: connection.host) else {
                throw connection.failure("No Siri question has been sent to this computer yet. Choose a session or ask Autolith a question first.")
            }
            id = latest
        }
        let sessions = try await connection.call(["operation": "list"]).sessions ?? []
        guard let current = sessions.first(where: { $0.id == id }) else { throw connection.failure("That session is no longer available.") }
        SiriConversationMemory.remember(id: current.id, host: connection.host)
        if current.isWorking {
            return .result(value: "Autolith is still working.", dialog: "Autolith is still working. Ask again shortly.")
        }
        let events = try await connection.call(["operation": "transcript", "id": id, "after": 0]).events ?? []
        guard let event = SiriContent.latestAnswerEvent(in: events) else {
            let message = "There is no answer yet. The session is \(current.state). Open Autolith to check whether it needs your attention."
            return .result(value: message, dialog: "\(message)")
        }
        let answer = try await SiriMessageReading.read(event, sessionID: id, connection: connection).text
        let spoken = answer.count > 1200 ? String(answer.prefix(1200)) + "… The full answer is in Autolith." : answer
        return .result(value: answer, dialog: "\(spoken)")
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchAutolithIntent: ShowInAppSearchResultsIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "Find existing Autolith sessions"
    static var description = IntentDescription("Filter existing conversations by title or workspace. This action does not ask questions, run tasks, or create sessions. Use Ask Autolith to dispatch work.")
    static var searchScopes: [StringSearchScope] = [.general]
    var criteria: StringSearchCriteria
    @MainActor func perform() async throws -> some IntentResult {
        SiriInvocation.record("Find existing sessions")
        SiriNavigationState.shared.search = criteria.term
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenAutolithSessionIntent: OpenIntent {
    var target: AutolithSessionEntity
    @MainActor func perform() async throws -> some IntentResult {
        let connection = try SiriSessionService.connected()
        SiriInvocation.record("Open session")
        try SiriSessionService.requireHost(target.host, connection: connection)
        SiriNavigationState.shared.sessionID = (target.host, target.sessionID)
        return .result()
    }
}

struct AutolithShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskAutolithIntent(), phrases: ["Start a task in \(.applicationName)", "Start a task in \(.applicationName) in \(\.$workspace)", "Ask \(.applicationName)", "Ask \(.applicationName) a question", "Have \(.applicationName) start a task", "Send a question to \(.applicationName)", "Ask \(.applicationName) in \(\.$workspace)"], shortTitle: "Ask Autolith", systemImageName: "terminal")
        AppShortcut(intent: StopAutolithTaskIntent(), phrases: ["Stop my \(.applicationName) task", "Stop my \(.applicationName) task in \(\.$workspace)"], shortTitle: "Stop task", systemImageName: "stop.circle")
        if #available(iOS 27.0, macOS 27.0, *) {
            AppShortcut(intent: ReadLatestAutolithResponseIntent(), phrases: ["Read my latest \(.applicationName) message", "Read the latest message from \(.applicationName)", "Read my latest \(.applicationName) answer", "Get my answer from \(.applicationName)", "What is the latest response from \(.applicationName)"], shortTitle: "Read message", systemImageName: "message")
            AppShortcut(intent: ReplyToAutolithConversationIntent(), phrases: ["Follow up with \(.applicationName)", "Continue my \(.applicationName) conversation", "Reply to \(.applicationName)"], shortTitle: "Follow up", systemImageName: "arrowshape.turn.up.left")
            AppShortcut(intent: AutolithConversationStatusIntent(), phrases: ["Check \(.applicationName) progress", "What is \(.applicationName) doing", "Check \(.applicationName) progress in \(\.$workspace)"], shortTitle: "Check progress", systemImageName: "chart.bar")
            AppShortcut(intent: ReadAutolithConversationIntent(), phrases: ["Read my \(.applicationName) answer in \(\.$workspace)"], shortTitle: "Read answer", systemImageName: "text.bubble")
        }
    }
}
