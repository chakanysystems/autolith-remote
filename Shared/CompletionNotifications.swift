import Foundation

struct CompletionNotifications: Codable, Sendable {
    private(set) var working: Set<String> = []
    private(set) var announced: [String: String] = [:]

    mutating func baseline(sessionID: String, events: [Event]) {
        let preceding = events.prefix(events.lastIndex(where: { $0.role == "user" }) ?? events.count)
        announced[sessionID] = preceding.last(where: { $0.role == "assistant" })?.id
    }

    mutating func completed(_ sessions: [Session]) -> [Session] {
        let candidates = sessions.filter { working.contains($0.id) && !$0.isWorking }
        working.formUnion(sessions.filter(\.isWorking).map(\.id))
        working.formIntersection(Set(sessions.map(\.id)))
        return candidates
    }

    mutating func acknowledge(sessionID: String, eventID: String) -> Bool {
        working.remove(sessionID)
        guard announced[sessionID] != eventID else { return false }
        announced[sessionID] = eventID
        return true
    }
}
