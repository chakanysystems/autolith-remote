import Foundation

struct Event: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    let tool: String
    let text: String
    var timestamp: Double? = nil
    var isRead: Bool? = nil
    var deliveryState: String? = nil
    var dispatchAt: Double? = nil

    var outboxRequestID: String? {
        guard id.hasPrefix("outbox-") else { return nil }
        let request = String(id.dropFirst(7))
        return UUID(uuidString: request) == nil ? nil : request
    }
    var isDeliveryPending: Bool { ["queued", "preparing", "dispatching"].contains(deliveryState ?? "") }
    var canRetryDelivery: Bool { outboxRequestID != nil && deliveryState == "failed" }
    var canAbandonDelivery: Bool { outboxRequestID != nil && ["queued", "failed", "uncertain"].contains(deliveryState ?? "") }
}

enum SiriContent {
    enum QuestionError: LocalizedError {
        case empty
        var errorDescription: String? { "Please provide a question." }
    }

    static func question(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw QuestionError.empty }
        // The prose prefix keeps dictated slash commands and Lisp as model input.
        return "Question from Siri:\n" + text
    }

    static func latestAnswer(in events: [Event]) -> String? {
        latestAnswerEvent(in: events)?.text
    }

    static func latestAnswerEvent(in events: [Event]) -> Event? {
        // An older unresolved receipt is not a new turn after a later executed prompt.
        let latestTurn = events.last { $0.role == "user" && !$0.id.hasPrefix("outbox-") }?.timestamp
        let turns = events.filter { event in
            if event.id.hasPrefix("outbox-"), event.deliveryState == "failed" { return false }
            guard event.id.hasPrefix("outbox-"), event.deliveryState == "uncertain",
                  let created = event.timestamp, let latestTurn else { return true }
            return created >= latestTurn
        }
        let start = turns.lastIndex { $0.role == "user" }.map { $0 + 1 } ?? 0
        return turns.dropFirst(start).last { $0.role == "assistant" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
