import Foundation

enum SiriMessageReceipt {
    enum Failure: LocalizedError {
        case unconfirmed
        var errorDescription: String? { "The computer did not confirm this message. Check the conversation before sending again." }
    }
    static func confirmed(_ ok: Bool?) throws {
        guard ok == true else { throw Failure.unconfirmed }
    }
    static func accepted(events: [Event], requestID: String, text: String) throws -> Event {
        guard events.count == 1, let event = events.first,
              event.id == "outbox-" + requestID, event.role == "user", event.text == text,
              (event.isDeliveryPending || event.deliveryState == "sent"), SiriMessageIdentity.date(for: event) != nil,
              let dispatchAt = event.dispatchAt, dispatchAt.isFinite else { throw Failure.unconfirmed }
        return event
    }
}
