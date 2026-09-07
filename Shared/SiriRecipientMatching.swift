import Foundation

/// Resolve durable recipient identity first; ambiguous names remain ambiguous.
enum SiriRecipientMatching {
    struct Candidate {
        let id: String
        let name: String
    }
    static func identifiers(applicationID: String?, name: String, candidates: [Candidate]) -> [String] {
        if let applicationID {
            let exact = candidates.filter { $0.id == applicationID }.map(\.id)
            if !exact.isEmpty { return exact }
            // A scoped conversation reference must never be replaced by a name match.
            if applicationID.contains("#") || applicationID.contains("://") { return [] }
            // Siri can synthesize an identifier while resolving a person by name.
            // Apple's messaging sample resolves those person references by display name.
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        return candidates.filter { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }.map(\.id)
    }
}
