import AppIntents
import Foundation

@available(iOS 27.0, macOS 27.0, *)
struct AutolithConversationStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Autolith conversation progress"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Conversation") var conversation: AutolithConversationEntity?
    @Parameter(title: "Workspace") var workspace: AutolithWorkspaceEntity?
    static var parameterSummary: some ParameterSummary { Summary("Check \(\.$conversation) in \(\.$workspace)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[AutolithConversationEntity]> & ProvidesDialog {
        SiriInvocation.record("Check conversation progress")
        let (connection, sessions) = try await SiriSessionService.sessions()
        if let conversation { try SiriSessionService.requireHost(conversation.host, connection: connection) }
        if let workspace { try SiriSessionService.requireHost(workspace.host, connection: connection) }
        let path = workspace?.path ?? (conversation == nil ? SiriWorkspaceConfiguration.load(host: connection.host).defaultPath : nil)
        let matching = sessions.filter { (path == nil || $0.workspace == path) && (conversation == nil || $0.id == conversation?.sessionID) }
        SiriTrace.record("Status: matching conversations", count: matching.count)
        guard let selected = SiriConversationSelection.latest(in: matching, preferredID: SiriConversationMemory.identifier(host: connection.host)) else {
            SiriTrace.record("Status: empty result prepared", count: 0)
            return .result(value: [], dialog: "There are no matching Autolith conversations.")
        }
        let entity = try await AutolithConversationContext.entity(selected, connection: connection)
        await AutolithConversationContext.remember(entity)
        let message = SiriConversationSelection.progress(sessions: matching, selected: selected)
        SiriTrace.record("Status: conversation result prepared", sessionID: entity.sessionID, count: 1, hasResponse: entity.latestResponse != nil)
        return .result(value: [entity], dialog: "\(message)")
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ReadAutolithConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Autolith conversation response"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Conversation") var conversation: AutolithConversationEntity?
    @Parameter(title: "Workspace") var workspace: AutolithWorkspaceEntity?
    static var parameterSummary: some ParameterSummary { Summary("Read the latest response in \(\.$conversation) in \(\.$workspace)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<AutolithConversationEntity> & ProvidesDialog {
        SiriInvocation.record("Read conversation response")
        let (connection, sessions) = try await SiriSessionService.sessions()
        if let conversation { try SiriSessionService.requireHost(conversation.host, connection: connection) }
        if let workspace { try SiriSessionService.requireHost(workspace.host, connection: connection) }
        let explicitID = conversation?.sessionID ?? (workspace == nil ? SiriConversationMemory.identifier(host: connection.host) : nil)
        let matching = sessions.filter { (workspace == nil || $0.workspace == workspace?.path) && (explicitID == nil || $0.id == explicitID) }
        guard let selected = SiriConversationSelection.latest(in: matching, preferredID: nil) else {
            throw connection.failure("That Autolith conversation is no longer available.")
        }
        let entity = try await AutolithConversationContext.entity(selected, connection: connection)
        await AutolithConversationContext.remember(entity)
        let response = entity.latestResponse ?? (selected.isWorking ? "Autolith is still working. There is no response to the latest prompt yet." : "There is no response to the latest prompt. The conversation is \(selected.state).")
        let spoken = response.count > 1200 ? String(response.prefix(1200)) + "… The full response is in Autolith." : response
        SiriTrace.record("Read: conversation result prepared", sessionID: entity.sessionID, hasResponse: entity.latestResponse != nil)
        return .result(value: entity, dialog: "\(spoken)")
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ReplyToAutolithConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Reply to Autolith conversation"
    static let description = IntentDescription("Send a follow-up question to this existing Autolith conversation, preserving its ID and history.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Conversation") var conversation: AutolithConversationEntity?
    @Parameter(title: "Question") var question: String?
    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$question) to \(\.$conversation)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<AutolithConversationEntity> & ProvidesDialog {
        SiriInvocation.record("Reply to conversation: started")
        let (connection, sessions) = try await SiriSessionService.sessions()
        if let conversation { try SiriSessionService.requireHost(conversation.host, connection: connection) }
        guard let id = conversation?.sessionID ?? SiriConversationMemory.identifier(host: connection.host),
              let selected = sessions.first(where: { $0.id == id }) else {
            throw connection.failure("Choose an existing Autolith conversation first. No new conversation was created.")
        }
        let input: String
        if let question { input = question }
        else { input = try await $question.requestValue("What would you like to add to \(selected.title)?") }
        try await SiriFollowUp.send(question: input, session: selected) { payload in
            try await connection.call(payload).id
        }
        // Acknowledgement can precede the next transcript update; do not expose the old answer.
        SiriConversationMemory.sent(id: selected.id, host: connection.host)
        var entity = AutolithConversationEntity(session: selected, host: connection.host, events: [])
        entity.status = "Request sent"
        entity.attributes = [.working]
        entity.previewText = "The follow-up was sent. Waiting for a response."
        await AutolithConversationContext.remember(entity)
        SiriInvocation.record("Reply to conversation: sent")
        return .result(value: entity, dialog: "Sent to \(selected.title) in Autolith.")
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenAutolithConversationIntent: OpenIntent {
    var target: AutolithConversationEntity
    @MainActor func perform() async throws -> some IntentResult {
        let connection = try SiriSessionService.connected()
        try SiriSessionService.requireHost(target.host, connection: connection)
        SiriNavigationState.shared.sessionID = target.sessionID
        return .result()
    }
}
