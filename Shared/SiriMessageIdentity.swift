import Foundation

struct SiriMessageIdentity: Codable, Hashable {
    let host: String
    let sessionID: String
    let eventID: String

    var id: String {
        // Length-delimited JSON fields avoid collisions with characters in a host or ID.
        let data = try! JSONEncoder().encode([host, sessionID, eventID])
        return data.base64EncodedString()
    }

    init(host: String, sessionID: String, eventID: String) {
        self.host = (try? CompanionEndpoint.canonical(host)) ?? host
        self.sessionID = sessionID
        self.eventID = eventID
    }

    init?(id: String) {
        guard let data = Data(base64Encoded: id),
              let fields = try? JSONDecoder().decode([String].self, from: data), fields.count == 3,
              fields.allSatisfy({ !$0.isEmpty }) else { return nil }
        self.init(host: fields[0], sessionID: fields[1], eventID: fields[2])
    }

    static func date(for event: Event) -> Date? {
        guard ["user", "assistant"].contains(event.role),
              !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ((Int(event.id).map { $0 >= 0 }) == true ||
               (event.id.hasPrefix("outbox-") && UUID(uuidString: String(event.id.dropFirst(7))) != nil)),
              let time = event.timestamp, time.isFinite else { return nil }
        return Date(timeIntervalSince1970: time)
    }
}
