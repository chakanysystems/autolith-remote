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
            guard event.id.hasPrefix("outbox-"), event.deliveryState == "uncertain",
                  let created = event.timestamp, let latestTurn else { return true }
            return created >= latestTurn
        }
        let start = turns.lastIndex { $0.role == "user" }.map { $0 + 1 } ?? 0
        return turns.dropFirst(start).last { $0.role == "assistant" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
