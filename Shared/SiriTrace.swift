import Foundation

// This trace records control flow only. It has no fields for user or model text.
@MainActor enum SiriTrace {
    struct Entry: Codable, Identifiable {
        let id: UUID
        let date: Date
        let stage: String
        let sessionID: String?
        let count: Int?
        let hasResponse: Bool?
        let errorCode: Int?
        let eventID: String?
    }

    static let limit = 100
    static let key = "siriControlTrace"

    static func entries(defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    static func record(_ stage: String, sessionID: String? = nil, count: Int? = nil,
                       hasResponse: Bool? = nil, errorCode: Int? = nil,
                       eventID: String? = nil,
                       defaults: UserDefaults = .standard) {
        let entry = Entry(id: UUID(), date: Date(), stage: stage, sessionID: sessionID,
                          count: count, hasResponse: hasResponse, errorCode: errorCode, eventID: eventID)
        let recent = Array((entries(defaults: defaults) + [entry]).suffix(limit))
        if let data = try? JSONEncoder().encode(recent) { defaults.set(data, forKey: key) }
    }
}
