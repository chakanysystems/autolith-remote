import AppIntents
import Foundation

@available(iOS 27.0, macOS 27.0, *)
@MainActor enum SiriInteractionDonation {
    static func sent(text: String, session: Session, connection: Connection, after sequence: Int) async {
        do {
            let host = connection.host
            let events = try await connection.call(["operation": "transcript", "id": session.id, "after": sequence]).events ?? []
            guard connection.host == host,
                  let event = events.last(where: { $0.role == "user" && $0.text == text && (Int($0.id) ?? -1) > sequence }) else { return }
            let conversation = AutolithConversationEntity(session: session, host: host, events: events)
            guard let message = AutolithMessageEntity(event: event, conversation: conversation) else { return }
            let intent = SendAutolithMessageIntent()
            intent.destination = .contact(AutolithAgentEntity(host: host, sessionID: session.id, title: session.title))
            intent.content = AttributedString(text)
            try await IntentDonationManager.shared.donate(intent: intent, result: .result(value: [message]))
            SiriTrace.record("UI message: interaction donated", sessionID: session.id, eventID: event.id)
        } catch {
            SiriTrace.record("UI message: donation failed", sessionID: session.id, errorCode: (error as NSError).code)
        }
    }
}
