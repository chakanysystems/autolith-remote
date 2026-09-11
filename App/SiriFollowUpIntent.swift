import AppIntents
import Foundation

struct FollowUpAutolithIntent: AppIntent {
    static var title: LocalizedStringResource = "Follow up with Autolith"
    static var description = IntentDescription("Send another question to the same Autolith conversation. Defaults to the last conversation used through these actions, preserving its history.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Session") var session: AutolithSessionEntity?
    @Parameter(title: "Follow-up") var question: String?
    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$question) to \(\.$session)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<AutolithSessionEntity> & ProvidesDialog {
        SiriInvocation.record("Follow-up: finding conversation")
        let (connection, sessions) = try await SiriSessionService.sessions()
        let id: String
        if let session {
            try SiriSessionService.requireHost(session.host, connection: connection)
            id = session.sessionID
        } else {
            guard let remembered = SiriConversationMemory.identifier(host: connection.host) else {
                throw connection.failure("No previous Siri conversation on this Mac. Ask Autolith a question first, or choose a session in Shortcuts.")
            }
            id = remembered
        }
        guard let current = sessions.first(where: { $0.id == id }) else {
            throw connection.failure("The previous conversation is no longer available. No new conversation was created.")
        }
        let input: String
        if let question { input = question }
        else {
            SiriInvocation.record("Follow-up: waiting for dictation")
            input = try await $question.requestValue("What would you like to add to \(current.title)?")
        }
        SiriInvocation.record("Follow-up: dictation received")
        try await SiriFollowUp.send(question: input, session: current) { payload in
            try await connection.call(payload).id
        }
        SiriConversationMemory.sent(id: current.id, host: connection.host)
        SiriInvocation.record("Follow-up: sent to existing conversation")
        return .result(value: AutolithSessionEntity(session: current, host: connection.host), dialog: "Sent to the same Autolith conversation. Say “Read my latest Autolith answer” to check the response.")
    }
}
