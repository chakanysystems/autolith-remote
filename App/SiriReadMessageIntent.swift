import AppIntents
import Foundation

@available(iOS 27.0, macOS 27.0, *)
struct ReadLatestAutolithResponseIntent: AppIntent {
    static let title: LocalizedStringResource = "Read response to my last Autolith request"
    static let description = IntentDescription("Fetch the current answer from the Mac for the conversation most recently sent to. Reports pending work instead of reading an older answer.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[AutolithMessageEntity]> & ProvidesDialog {
        let (connection, sessions) = try await SiriSessionService.sessions()
        guard let id = SiriConversationMemory.lastSentIdentifier(host: connection.host) ?? SiriConversationMemory.identifier(host: connection.host),
              let session = sessions.first(where: { $0.id == id }) else {
            throw connection.failure("Send Autolith a question first. The last requested conversation is not available on this Mac.")
        }
        SiriTrace.record("Read latest: last requested conversation", sessionID: id)
        var intent = ReadAutolithMessageIntent()
        intent.conversation = AutolithConversationEntity(session: session, host: connection.host, events: [])
        return try await intent.perform()
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ReadAutolithMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Read latest Autolith message"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Conversation") var conversation: AutolithConversationEntity?
    @Parameter(title: "Workspace") var workspace: AutolithWorkspaceEntity?
    static var parameterSummary: some ParameterSummary { Summary("Read the latest message in \(\.$conversation) in \(\.$workspace)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[AutolithMessageEntity]> & ProvidesDialog {
        SiriInvocation.record("Read message: started")
        let (connection, sessions) = try await SiriSessionService.sessions()
        if let conversation { try SiriSessionService.requireHost(conversation.host, connection: connection) }
        if let workspace { try SiriSessionService.requireHost(workspace.host, connection: connection) }
        let id = conversation?.sessionID ?? (workspace == nil ? SiriConversationMemory.identifier(host: connection.host) : nil)
        let matching = sessions.filter { (id == nil || $0.id == id) && (workspace == nil || $0.workspace == workspace?.path) }
        guard let selected = SiriConversationSelection.latest(in: matching, preferredID: nil) else {
            throw connection.failure("That Autolith conversation is no longer available.")
        }
        guard !selected.isWorking else { return .result(value: [], dialog: "Autolith is still working on that conversation.") }
        var events = try await connection.call(["operation": "transcript", "id": selected.id, "after": 0]).events ?? []
        guard var answer = SiriContent.latestAnswerEvent(in: events) else {
            return .result(value: [], dialog: "There is no answer to the latest prompt yet.")
        }
        answer = try await SiriMessageReading.read(answer, sessionID: selected.id, connection: connection)
        if let offset = events.firstIndex(where: { $0.id == answer.id }) { events[offset] = answer }
        let entity = AutolithConversationEntity(session: selected, host: connection.host, events: events)
        guard let message = AutolithMessageEntity(event: answer, conversation: entity) else {
            throw connection.failure("This response has no durable message date. Update the Mac companion backend before using message retrieval.")
        }
        await AutolithConversationContext.remember(entity)
        await SiriMessageMaintenance.update(host: connection.host, sessionID: selected.id) {
            try await AutolithMessageContext.index([message])
        }
        SiriTrace.record("Read message: result prepared", sessionID: selected.id, count: 1, hasResponse: true, eventID: answer.id)
        let spoken = answer.text.count > 1200 ? String(answer.text.prefix(1200)) + "… The full response is in Autolith." : answer.text
        return .result(value: [message], dialog: "\(spoken)")
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenAutolithMessageIntent: OpenIntent {
    var target: AutolithMessageEntity
    @MainActor func perform() async throws -> some IntentResult {
        let connection = try SiriSessionService.connected()
        try SiriSessionService.requireHost(target.conversation.host, connection: connection)
        SiriNavigationState.shared.sessionID = target.conversation.sessionID
        return .result()
    }
}
