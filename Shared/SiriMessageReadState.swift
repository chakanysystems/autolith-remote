import Foundation

extension Event {
    var hasBeenRead: Bool { isRead ?? (role != "assistant") }
}

/// Reading changes local state only after the companion confirms the receipt.
@MainActor enum SiriMessageReadState {
    static func markRead(_ event: Event, persist: () async throws -> Bool?) async throws -> Event {
        guard !event.hasBeenRead, SiriMessageIdentity.date(for: event) != nil else { return event }
        try SiriMessageReceipt.confirmed(await persist())
        var updated = event
        updated.isRead = true
        return updated
    }
}
