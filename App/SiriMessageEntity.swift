import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation
import GeoToolbox
import LinkPresentation

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.message)
struct AutolithMessageEntity: IndexedEntity, Transferable {
    static let defaultQuery = AutolithMessageQuery()
    let id: String
    var messageType: AutolithMessageType
    var author: AutolithAgentEntity
    var isRead: Bool
    var attributes: Set<AutolithMessageAttribute>
    var conversation: AutolithConversationEntity
    var date: Date
    var subject: AttributedString?
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [AutolithMessageAttachment]
    var locations: [PlaceDescriptor]
    var links: [LinkMetadata]
    var messageEffect: AutolithMessageEffect?
    var reaction: AutolithMessageReaction?
    var referencedMessage: AutolithMessageEntity?
    var notificationIdentifier: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(body ?? "")", subtitle: "\(conversation.displayName)")
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { message in String((message.body ?? "").characters) })
    }

    init?(event: Event, conversation: AutolithConversationEntity) {
        guard let date = SiriMessageIdentity.date(for: event) else { return nil }
        id = SiriMessageIdentity(host: conversation.host, sessionID: conversation.sessionID, eventID: event.id).id
        messageType = .unspecified
        author = AutolithAgentEntity(host: conversation.host, isMe: event.role == "user", sessionID: conversation.sessionID, title: conversation.displayName)
        isRead = event.hasBeenRead
        attributes = event.isDeliveryPending ? [.queued] : event.deliveryState == "uncertain" ? [.deliveryUncertain] : event.deliveryState == "failed" ? [.deliveryFailed] : []
        self.conversation = conversation
        self.date = date
        body = AttributedString(event.text)
        attachments = []
        customAttachments = []
        locations = []
        links = []
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.messageType)
enum AutolithMessageType: String { case unspecified
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.unspecified: "Text"]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.messageAttribute)
enum AutolithMessageAttribute: String { case favorited, queued, deliveryUncertain, deliveryFailed
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.favorited: "Favorited", .queued: "Queued", .deliveryUncertain: "Delivery uncertain", .deliveryFailed: "Not delivered"]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.messageEffect)
enum AutolithMessageEffect: String { case love
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.love: "Love"]
}

@available(iOS 27.0, macOS 27.0, *)
@UnionValue enum AutolithMessageReaction { case customReaction(AutolithCustomReaction) }

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.customReaction)
enum AutolithCustomReaction: String { case sticker
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.sticker: "Sticker"]
}

// Required schema type. Autolith's text transcript has no custom attachments.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.customAttachment)
struct AutolithMessageAttachment {
    static let defaultQuery = AttachmentQuery()
    let id: String
    var sourceName: AttributedString?
    var description: AttributedString?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(description ?? "")") }
    struct AttachmentQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [AutolithMessageAttachment] { [] }
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct AutolithMessageQuery: EntityQuery, IndexedEntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [AutolithMessageEntity] {
        SiriTrace.record("Message query: resolve IDs", count: identifiers.count)
        let (connection, sessions) = try await SiriSessionService.sessions()
        let identities = identifiers.compactMap(SiriMessageIdentity.init(id:)).filter { $0.host == connection.host }
        var messages: [AutolithMessageEntity] = []
        for session in sessions where identities.contains(where: { $0.sessionID == session.id }) {
            let eventIDs = Array(Set(identities.filter { $0.sessionID == session.id }.map(\.eventID)))
            for offset in stride(from: 0, to: eventIDs.count, by: 100) {
                let batch = Array(eventIDs[offset..<min(offset + 100, eventIDs.count)])
                let reply = try await connection.call(["operation": "message-events", "id": session.id, "eventIDs": batch])
                let conversation = AutolithConversationEntity(session: session, host: connection.host, events: [])
                messages += (reply.events ?? []).compactMap { AutolithMessageEntity(event: $0, conversation: conversation) }
            }
        }
        SiriTrace.record("Message query: IDs resolved", count: messages.count)
        for message in messages {
            if let identity = SiriMessageIdentity(id: message.id) {
                SiriTrace.record("Message query: returned event", sessionID: identity.sessionID, eventID: identity.eventID)
            }
        }
        return messages
    }

    @MainActor func suggestedEntities() async throws -> [AutolithMessageEntity] {
        SiriTrace.record("Message query: recent messages")
        let (connection, sessions) = try await SiriSessionService.sessions()
        var messages: [AutolithMessageEntity] = []
        for session in sessions.prefix(5) {
            messages += try await AutolithMessageContext.messages(session, connection: connection)
        }
        return Array(messages.sorted { $0.date > $1.date }.prefix(10))
    }

    @MainActor func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        let messages = try await entities(for: identifiers)
        let missing = Set(identifiers).subtracting(messages.map(\.id))
        try await AutolithConversationContext.index.deleteAppEntities(identifiedBy: Array(missing), ofType: AutolithMessageEntity.self)
        AutolithConversationContext.forget(Array(missing), key: "siriIndexedMessages")
        try await AutolithMessageContext.index(messages)
    }

    @MainActor func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let (connection, sessions) = try await SiriSessionService.sessions()
        try await AutolithConversationContext.index.deleteAppEntities(ofType: AutolithMessageEntity.self)
        UserDefaults.standard.removeObject(forKey: "siriIndexedMessages")
        for session in sessions {
            try await AutolithMessageContext.index(AutolithMessageContext.messages(session, connection: connection))
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@MainActor enum AutolithMessageContext {
    private static var indexedEvents: [String: [String: Event]] = [:]
    private static var indexedSessions: [String: Session] = [:]
    static func messages(_ session: Session, connection: Connection) async throws -> [AutolithMessageEntity] {
        let host = connection.host
        let events = try await connection.call(["operation": "transcript", "id": session.id, "after": 0]).events ?? []
        let (conversation, messages) = try await BackgroundWork.run {
            let conversation = AutolithConversationEntity(session: session, host: host, events: events)
            return (conversation, events.compactMap { AutolithMessageEntity(event: $0, conversation: conversation) })
        }
        guard connection.host == host else { throw CancellationError() }
        do {
            try await index(messages)
            try await AutolithConversationContext.indexEntities([conversation])
        } catch {
            SiriTrace.record("Message query: refresh indexing failed", sessionID: session.id, errorCode: (error as NSError).code)
        }
        return messages
    }

    static func index(_ messages: [AutolithMessageEntity]) async throws {
        guard !messages.isEmpty else { return }
        try await AutolithConversationContext.index.indexAppEntities(messages)
        let known = Set(UserDefaults.standard.stringArray(forKey: "siriIndexedMessages") ?? [])
        UserDefaults.standard.set(Array(known.union(messages.map(\.id))), forKey: "siriIndexedMessages")
    }

    static func synchronize(host: String, sessions: [Session], events: [String: [Event]]) async throws {
        let known = UserDefaults.standard.stringArray(forKey: "siriIndexedMessages") ?? []
        let previousEvents = indexedEvents, previousSessions = indexedSessions
        let plan = try await BackgroundWork.run(priority: .utility) {
            SiriMessageIndexPlan(host: host, sessions: sessions, events: events, known: known,
                                 indexedEvents: previousEvents, indexedSessions: previousSessions)
        }
        let removed = plan.removed
        if !removed.isEmpty {
            try await AutolithConversationContext.index.deleteAppEntities(identifiedBy: removed, ofType: AutolithMessageEntity.self)
            let current = UserDefaults.standard.stringArray(forKey: "siriIndexedMessages") ?? []
            UserDefaults.standard.set(current.filter { !removed.contains($0) }, forKey: "siriIndexedMessages")
        }
        for batch in plan.batches {
            let session = batch.session, transcript = batch.transcript
            let key = host + "#" + session.id
            let conversation = try await BackgroundWork.run(priority: .utility) {
                AutolithConversationEntity(session: session, host: host, events: transcript)
            }
            let changed = batch.changed
            for start in stride(from: 0, to: changed.count, by: 50) {
                try Task.checkCancellation()
                let end = min(start + 50, changed.count)
                let messages = try await BackgroundWork.run(priority: .utility) {
                    changed[start..<end].compactMap { AutolithMessageEntity(event: $0, conversation: conversation) }
                }
                try await index(messages)
            }
            indexedEvents[key] = batch.byID
            indexedSessions[key] = session
        }
        let retained = Set(sessions.map { host + "#" + $0.id })
        indexedEvents = indexedEvents.filter { retained.contains($0.key) }
        indexedSessions = indexedSessions.filter { retained.contains($0.key) }
        if !events.isEmpty {
            let cached = Set(events.keys.map { host + "#" + $0 })
            indexedEvents = indexedEvents.filter { cached.contains($0.key) }
            indexedSessions = indexedSessions.filter { cached.contains($0.key) }
        }
    }
}
