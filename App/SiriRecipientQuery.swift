import AppIntents
import CoreTransferable
import Foundation

@available(iOS 27.0, macOS 27.0, *)
extension AutolithAgentEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        IntentValueRepresentation(exporting: \.person)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AutolithAgentEntity.Query: IntentValueQuery {
    private func name(_ person: IntentPerson) -> String {
        switch person.name {
        case .displayName(let value): return value
        case .components(let components): return PersonNameComponentsFormatter.localizedString(from: components, style: .default)
        case .unknown: return ""
        @unknown default: return ""
        }
    }
    @MainActor func suggestedEntities() async throws -> [AutolithAgentEntity] {
        let (connection, sessions) = try await SiriSessionService.sessions()
        let recent = sessions.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }.prefix(10)
        return [AutolithAgentEntity(host: connection.host)] + recent.map {
            AutolithAgentEntity(host: connection.host, sessionID: $0.id, title: $0.title)
        }
    }

    @MainActor func values(for input: [IntentPerson]) async throws -> [AutolithAgentEntity] {
        SiriTrace.record("Recipients: resolving Siri people", count: input.count)
        let (connection, sessions) = try await SiriSessionService.sessions()
        let candidates = [AutolithAgentEntity(host: connection.host)] + sessions.map {
            AutolithAgentEntity(host: connection.host, sessionID: $0.id, title: $0.title)
        }
        let names = candidates.map { SiriRecipientMatching.Candidate(id: $0.id, name: name($0.person)) }
        var ids = Set<String>()
        for person in input {
            guard !person.isMe else {
                SiriTrace.record("Recipients: input is self")
                continue
            }
            let applicationID: String?
            if case .applicationDefined(let id) = person.identifier { applicationID = CompanionEndpoint.canonicalEntityID(id) }
            else { applicationID = nil }
            let matched = SiriRecipientMatching.identifiers(applicationID: applicationID, name: name(person), candidates: names)
            let category = applicationID == nil ? "system person" : names.contains(where: { $0.id == applicationID }) ? "known app ID" : "unknown app ID"
            SiriTrace.record("Recipients: " + category, count: matched.count)
            if matched.isEmpty {
                let byName = SiriRecipientMatching.identifiers(applicationID: nil, name: name(person), candidates: names)
                SiriTrace.record("Recipients: name matches", count: byName.count)
            }
            ids.formUnion(matched)
        }
        let result = candidates.filter { ids.contains($0.id) }
        SiriTrace.record("Recipients: Siri people resolved", count: result.count)
        return result
    }
}
