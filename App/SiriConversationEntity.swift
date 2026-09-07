import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.messagePerson)
struct AutolithAgentEntity: IndexedEntity {
    static let defaultQuery = Query()
    let id: String
    var person: IntentPerson
    var displayRepresentation: DisplayRepresentation {
        if case .displayName(let name) = person.name { return DisplayRepresentation(title: "\(name)") }
        return DisplayRepresentation(title: "Autolith")
    }

    init(host: String, isMe: Bool = false, sessionID: String? = nil, title: String? = nil) {
        let host = (try? CompanionEndpoint.canonical(host)) ?? host
        id = isMe ? host + "#me" : sessionID.map { host + "#session:" + $0 } ?? host
        person = IntentPerson(identifier: .applicationDefined(id), name: .displayName(isMe ? "Me" : title.map { "Autolith: " + $0 } ?? "Autolith"), handle: nil, isMe: isMe)
    }

    struct Query: EntityQuery, IndexedEntityQuery {
        @MainActor func entities(for identifiers: [String]) async throws -> [AutolithAgentEntity] {
            let identifiers = identifiers.map(CompanionEndpoint.canonicalEntityID)
            let connection = try SiriSessionService.connected()
            var entities = [AutolithAgentEntity(host: connection.host), AutolithAgentEntity(host: connection.host, isMe: true)]
            if identifiers.contains(where: { $0.hasPrefix(connection.host + "#session:") }) {
                let sessions = try await connection.call(["operation": "list"]).sessions ?? []
                entities += sessions.map { AutolithAgentEntity(host: connection.host, sessionID: $0.id, title: $0.title) }
            }
            return entities.filter { identifiers.contains($0.id) }
        }

        @MainActor func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
            let entities = try await entities(for: identifiers)
            let missing = Set(identifiers).subtracting(entities.map(\.id))
            try await AutolithConversationContext.index.deleteAppEntities(identifiedBy: Array(missing), ofType: AutolithAgentEntity.self)
            AutolithConversationContext.forget(Array(missing), key: "siriIndexedRecipients")
            try await AutolithConversationContext.indexRecipients(entities)
        }

        @MainActor func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
            let (connection, sessions) = try await SiriSessionService.sessions()
            try await AutolithConversationContext.index.deleteAppEntities(ofType: AutolithAgentEntity.self)
            UserDefaults.standard.removeObject(forKey: "siriIndexedRecipients")
            try await AutolithConversationContext.synchronizeRecipients(host: connection.host, sessions: sessions, force: true)
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.conversationAttribute)
enum AutolithConversationAttribute: String {
    case working
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.working: "Working"]
}

// Schema content uses the same host and durable session ID as the legacy shortcuts.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.conversation)
struct AutolithConversationEntity: IndexedEntity, Transferable {
    static let defaultQuery = AutolithConversationQuery()
    let id: String
    let host: String
    let sessionID: String
    var recipients: [AutolithAgentEntity]
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<AutolithConversationAttribute>
    var dateLastActive: Date?
    @Property(title: "Workspace") var workspace: String
    @Property(title: "Status") var status: String
    @Property(title: "Latest response") var latestResponse: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(workspace) · \(status)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let value = CSSearchableItemAttributeSet(contentType: .text)
        value.contentDescription = "\(workspace)\n\(status)\n\(latestResponse ?? "")"
        value.contentModificationDate = dateLastActive
        return value
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { entity in
            "\(entity.displayName)\n\(entity.workspace)\n\(entity.status)\n\(entity.latestResponse ?? "No response to the latest prompt yet.")"
        })
    }

    init(session: Session, host: String, events: [Event]) {
        let host = (try? CompanionEndpoint.canonical(host)) ?? host
        self.host = host
        sessionID = session.id
        id = host + "#" + session.id
        recipients = [AutolithAgentEntity(host: host, sessionID: session.id, title: session.title)]
        displayName = session.title
        conversationName = session.title
        workspace = session.workspace
        status = session.state
        latestResponse = session.isWorking ? nil : SiriContent.latestAnswer(in: events)
        previewText = AttributedString(latestResponse ?? (session.isWorking ? "Autolith is working." : "No response to the latest prompt yet."))
        isRead = events.allSatisfy(\.hasBeenRead)
        attributes = session.isWorking ? [.working] : []
        dateLastActive = session.updatedAt.map(Date.init(timeIntervalSince1970:))
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct AutolithConversationQuery: EntityStringQuery, IndexedEntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [AutolithConversationEntity] {
        let identifiers = identifiers.map(CompanionEndpoint.canonicalEntityID)
        SiriTrace.record("Query: resolve conversation IDs", count: identifiers.count)
        let (connection, sessions) = try await SiriSessionService.sessions()
        let result = try await load(sessions.filter { identifiers.contains(connection.host + "#" + $0.id) }, connection: connection)
        SiriTrace.record("Query: resolved conversation IDs", count: result.count)
        return result
    }

    @MainActor func suggestedEntities() async throws -> [AutolithConversationEntity] {
        SiriTrace.record("Query: suggested conversations")
        let (connection, sessions) = try await SiriSessionService.sessions()
        return try await load(Array(sessions.prefix(10)), connection: connection)
    }

    @MainActor func entities(matching string: String) async throws -> [AutolithConversationEntity] {
        SiriTrace.record("Query: match conversations")
        let (connection, sessions) = try await SiriSessionService.sessions()
        return try await load(sessions.filter {
            $0.title.localizedCaseInsensitiveContains(string) || $0.workspace.localizedCaseInsensitiveContains(string)
        }, connection: connection)
    }

    @MainActor private func load(_ sessions: [Session], connection: Connection) async throws -> [AutolithConversationEntity] {
        var entities: [AutolithConversationEntity] = []
        for session in sessions {
            try Task.checkCancellation()
            entities.append(try await AutolithConversationContext.entity(session, connection: connection))
        }
        return entities
    }

    @MainActor func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        let entities = try await entities(for: identifiers)
        let missing = Set(identifiers).subtracting(entities.map(\.id))
        if !missing.isEmpty {
            try await AutolithConversationContext.index.deleteAppEntities(identifiedBy: Array(missing), ofType: AutolithConversationEntity.self)
            AutolithConversationContext.forget(Array(missing), key: "siriIndexedConversations")
        }
        try await AutolithConversationContext.indexEntities(entities)
    }

    @MainActor func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let (connection, sessions) = try await SiriSessionService.sessions()
        let entities = try await load(sessions, connection: connection)
        try await AutolithConversationContext.index.deleteAppEntities(ofType: AutolithConversationEntity.self)
        UserDefaults.standard.removeObject(forKey: "siriIndexedConversations")
        try await AutolithConversationContext.indexEntities(entities)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@MainActor enum AutolithConversationContext {
    static let index = CSSearchableIndex(name: "AutolithConversations", protectionClass: .complete)

    static func entity(_ session: Session, connection: Connection) async throws -> AutolithConversationEntity {
        SiriTrace.record("Transcript: requested", sessionID: session.id)
        do {
            let events = try await connection.call(["operation": "transcript", "id": session.id, "after": 0]).events ?? []
            let entity = AutolithConversationEntity(session: session, host: connection.host, events: events)
            do {
                let messages = events.compactMap { AutolithMessageEntity(event: $0, conversation: entity) }
                try await AutolithMessageContext.index(messages)
                SiriTrace.record("Messages: indexed", sessionID: session.id, count: messages.count)
            } catch {
                SiriTrace.record("Messages: indexing failed", sessionID: session.id, errorCode: (error as NSError).code)
            }
            SiriTrace.record("Transcript: entity prepared", sessionID: session.id, count: events.count, hasResponse: entity.latestResponse != nil)
            return entity
        } catch {
            SiriTrace.record("Transcript: failed", sessionID: session.id, errorCode: (error as NSError).code)
            throw error
        }
    }

    static func remember(_ entity: AutolithConversationEntity) async {
        SiriConversationMemory.remember(id: entity.sessionID, host: entity.host)
        SiriTrace.record("Siri context: indexing requested", sessionID: entity.sessionID)
        do {
            try await indexEntities([entity])
            SiriTrace.record("Siri context: indexing succeeded", sessionID: entity.sessionID)
        } catch {
            SiriTrace.record("Siri context: indexing failed", sessionID: entity.sessionID, errorCode: (error as NSError).code)
            UserDefaults.standard.set(error.localizedDescription, forKey: "siriContextError")
        }
    }

    static func donate(_ entities: [AutolithConversationEntity]) async {
        do {
            try await indexEntities(entities)
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: "siriContextError")
        }
    }

    static func indexEntities(_ entities: [AutolithConversationEntity]) async throws {
        try await indexRecipients(entities.flatMap(\.recipients))
        try await index.indexAppEntities(entities)
        let known = Set(UserDefaults.standard.stringArray(forKey: "siriIndexedConversations") ?? [])
        UserDefaults.standard.set(Array(known.union(entities.map(\.id))), forKey: "siriIndexedConversations")
        UserDefaults.standard.removeObject(forKey: "siriContextError")
    }

    static func indexRecipients(_ entities: [AutolithAgentEntity]) async throws {
        // Earlier builds did not track recipients. Clear that type once to remove orphan entries.
        if !UserDefaults.standard.bool(forKey: "siriRecipientIndexManaged") {
            try await index.deleteAppEntities(ofType: AutolithAgentEntity.self)
            UserDefaults.standard.removeObject(forKey: "siriIndexedRecipients")
            UserDefaults.standard.set(true, forKey: "siriRecipientIndexManaged")
        }
        try await index.indexAppEntities(entities)
        let known = Set(UserDefaults.standard.stringArray(forKey: "siriIndexedRecipients") ?? [])
        UserDefaults.standard.set(Array(known.union(entities.map(\.id))), forKey: "siriIndexedRecipients")
    }

    static func synchronizeRecipients(host: String, sessions: [Session], force: Bool = false) async throws {
        if !force, recipientHost == host, recipientSessions == sessions { return }
        let entities = [AutolithAgentEntity(host: host), AutolithAgentEntity(host: host, isMe: true)] + sessions.map {
            AutolithAgentEntity(host: host, sessionID: $0.id, title: $0.title)
        }
        let valid = Set(entities.map(\.id))
        let known = Set(UserDefaults.standard.stringArray(forKey: "siriIndexedRecipients") ?? [])
        let removed = known.subtracting(valid)
        try await index.deleteAppEntities(identifiedBy: Array(removed), ofType: AutolithAgentEntity.self)
        let current = Set(UserDefaults.standard.stringArray(forKey: "siriIndexedRecipients") ?? [])
        UserDefaults.standard.set(Array(current.subtracting(removed)), forKey: "siriIndexedRecipients")
        try await indexRecipients(entities)
        recipientHost = host; recipientSessions = sessions
    }

    private static var recipientHost = ""
    private static var recipientSessions: [Session] = []
    private static var conversationSnapshots: [String: (Session, [Event])] = [:]

    static func forget(_ identifiers: [String], key: String) {
        let current = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        UserDefaults.standard.set(Array(current.subtracting(identifiers)), forKey: key)
    }

    static func retireOtherHosts(_ host: String) async {
        do {
            let conversations = UserDefaults.standard.stringArray(forKey: "siriIndexedConversations") ?? []
            let removed = conversations.filter { !$0.hasPrefix(host + "#") }
            try await index.deleteAppEntities(identifiedBy: removed, ofType: AutolithConversationEntity.self)
            forget(removed, key: "siriIndexedConversations")
            let messages = UserDefaults.standard.stringArray(forKey: "siriIndexedMessages") ?? []
            let oldMessages = messages.filter { SiriMessageIdentity(id: $0)?.host != host }
            try await index.deleteAppEntities(identifiedBy: oldMessages, ofType: AutolithMessageEntity.self)
            forget(oldMessages, key: "siriIndexedMessages")
            let recipients = UserDefaults.standard.stringArray(forKey: "siriIndexedRecipients") ?? []
            let oldRecipients = recipients.filter { $0 != host && !$0.hasPrefix(host + "#") }
            // Include recipients from builds that did not yet track their IDs.
            let legacy = removed.compactMap { id -> String? in
                guard let split = id.firstIndex(of: "#") else { return nil }
                return String(id[..<split]) + "#session:" + String(id[id.index(after: split)...])
            }
            try await index.deleteAppEntities(identifiedBy: oldRecipients + legacy, ofType: AutolithAgentEntity.self)
            forget(oldRecipients, key: "siriIndexedRecipients")
        } catch { UserDefaults.standard.set(error.localizedDescription, forKey: "siriContextError") }
    }

    // Use the successful list response to retire deleted conversations and old Mac entries.
    static func retireUnavailable(connection: Connection) async {
        let host = connection.host
        let valid = Set(connection.sessions.map { host + "#" + $0.id })
        let known = Set(UserDefaults.standard.stringArray(forKey: "siriIndexedConversations") ?? [])
        let removed = known.subtracting(valid)
        do {
            if !removed.isEmpty {
                try await index.deleteAppEntities(identifiedBy: Array(removed), ofType: AutolithConversationEntity.self)
                forget(Array(removed), key: "siriIndexedConversations")
            }
            guard connection.host == host else { return }
            try await AutolithMessageContext.synchronize(host: host, sessions: connection.sessions, events: [:])
            try await synchronizeRecipients(host: host, sessions: connection.sessions)
        } catch { UserDefaults.standard.set(error.localizedDescription, forKey: "siriContextError") }
    }

    static func synchronize(connection: Connection) async {
        do {
            try await SiriMessageMaintenance.repair(connection: connection)
            try await AutolithMessageContext.synchronize(host: connection.host, sessions: connection.sessions, events: connection.events)
            for session in connection.sessions {
                guard let events = connection.events[session.id] else { continue }
                let key = connection.host + "#" + session.id
                let previous = conversationSnapshots[key], host = connection.host
                let entity = try await BackgroundWork.run(priority: .utility) { () -> AutolithConversationEntity? in
                    if let previous, previous.0 == session, previous.1 == events { return nil }
                    return AutolithConversationEntity(session: session, host: host, events: events)
                }
                guard connection.host == host else { return }
                guard let entity else { continue }
                try await indexEntities([entity])
                conversationSnapshots[key] = (session, events)
            }
            let retained = Set(connection.events.keys.map { connection.host + "#" + $0 })
            conversationSnapshots = conversationSnapshots.filter { retained.contains($0.key) }
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: "siriContextError")
        }
    }
}
