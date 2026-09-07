import AppIntents
import Foundation
import GeoToolbox

@available(iOS 27.0, macOS 27.0, *)
@UnionValue enum AutolithMessageDestination {
    case contact(AutolithAgentEntity)
    case recipients([AutolithAgentEntity])
}

@available(iOS 27.0, macOS 27.0, *)
@MainActor enum SiriMessaging {
    static func session(destination: AutolithMessageDestination?) async throws -> (Connection, Session) {
        let (connection, sessions) = try await SiriSessionService.sessions()
        var explicitID: String?
        switch destination {
        case .contact(let contact):
            explicitID = try recipient(contact, connection: connection)
        case .recipients(let contacts):
            guard contacts.count == 1 else { throw connection.failure("Send to one Autolith conversation at a time.") }
            explicitID = try recipient(contacts[0], connection: connection)
        case nil: break
        }
        if let id = explicitID ?? SiriConversationMemory.identifier(host: connection.host) {
            guard let session = sessions.first(where: { $0.id == id }) else { throw connection.failure("That conversation no longer exists. Choose an existing conversation.") }
            return (connection, session)
        }
        guard let path = SiriWorkspaceConfiguration.load(host: connection.host).defaultPath else {
            throw connection.failure("Choose a default workspace in Autolith Settings, or ask Autolith a question first.")
        }
        guard let id = try await connection.call(["operation": "create", "workspace": path, "permissions": "ask"]).id else { throw connection.failure("The Mac did not return a conversation ID.") }
        SiriConversationMemory.remember(id: id, host: connection.host)
        return (connection, Session(id: id, title: "Siri conversation", state: "starting", workspace: path, model: "", permissions: "ask", queued: 0, jobs: 0, updatedAt: Date().timeIntervalSince1970))
    }

    private static func recipient(_ contact: AutolithAgentEntity, connection: Connection) throws -> String? {
        let id = CompanionEndpoint.canonicalEntityID(contact.id)
        if id == connection.host { return nil }
        let prefix = connection.host + "#session:"
        guard id.hasPrefix(prefix) else { throw connection.failure("Choose an Autolith recipient on the connected Mac.") }
        return String(id.dropFirst(prefix.count))
    }

    static func text(content: AttributedString?, subject: AttributedString?, attachments: [IntentFile], audio: IntentFile?, locations: [PlaceDescriptor], links: [URL], allowEmpty: Bool = false) throws -> String {
        guard subject == nil, attachments.isEmpty, audio == nil, locations.isEmpty, links.isEmpty else {
            throw NSError(domain: "Autolith", code: 1, userInfo: [NSLocalizedDescriptionKey: "Autolith messaging accepts text prompts. Attachments, locations, and separate subjects are not supported."])
        }
        let value = content.map { String($0.characters) } ?? ""
        if !allowEmpty { _ = try SiriContent.question(value) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func identity(_ message: AutolithMessageEntity, connection: Connection) throws -> SiriMessageIdentity {
        guard let identity = SiriMessageIdentity(id: message.id), identity.host == connection.host,
              identity.sessionID == message.conversation.sessionID else { throw connection.failure("That message belongs to another Mac or conversation.") }
        return identity
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.sendMessage)
struct SendAutolithMessageIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    var destination: AutolithMessageDestination
    var subject: AttributedString?
    var content: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @MainActor func perform() async throws -> some ReturnsValue<[AutolithMessageEntity]> {
        SiriInvocation.record("Messages: send started")
        let input: AttributedString
        if let content { input = content }
        else { input = try await $content.requestValue("What would you like to ask Autolith?") }
        let text = try SiriMessaging.text(content: input, subject: subject, attachments: attachments, audio: audioMessage, locations: locations, links: links)
        let (connection, session) = try await SiriMessaging.session(destination: destination)
        let requestID = UUID().uuidString
        var payload: [String: Any] = ["operation": "message-send", "id": session.id, "requestID": requestID, "text": text]
        if let scheduledDate { payload["scheduledDate"] = scheduledDate.timeIntervalSince1970 }
        let reply = try await connection.call(payload)
        let conversation = AutolithConversationEntity(session: session, host: connection.host, events: [])
        let event = try SiriMessageReceipt.accepted(events: reply.events ?? [], requestID: requestID, text: text)
        guard let message = AutolithMessageEntity(event: event, conversation: conversation) else { throw connection.failure("Delivery acknowledgement is incomplete. Check the conversation before retrying.") }
        SiriConversationMemory.sent(id: session.id, host: connection.host)
        await AutolithConversationContext.remember(conversation)
        await SiriMessageMaintenance.update(host: connection.host, sessionID: session.id) {
            try await AutolithMessageContext.index([message])
        }
        SiriTrace.record("Messages: send result prepared", sessionID: session.id, count: 1, eventID: event.id)
        return .result(value: [message])
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.draftMessage)
struct DraftAutolithMessageIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = true
    var destination: AutolithMessageDestination?
    var subject: AttributedString?
    var content: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @MainActor func perform() async throws -> some IntentResult {
        guard scheduledDate == nil else { throw NSError(domain: "Autolith", code: 1, userInfo: [NSLocalizedDescriptionKey: "Schedule the message when sending it, not when opening its draft."]) }
        let value = try SiriMessaging.text(content: content, subject: subject, attachments: attachments, audio: audioMessage, locations: locations, links: links, allowEmpty: true)
        let (connection, session) = try await SiriMessaging.session(destination: destination)
        SiriNavigationState.shared.draft = (session.id, value)
        SiriConversationMemory.remember(id: session.id, host: connection.host)
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.editSentMessage)
struct EditAutolithMessageIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    var message: AutolithMessageEntity
    var content: AttributedString
    @MainActor func perform() async throws -> some IntentResult {
        let connection = try SiriSessionService.connected()
        let identity = try SiriMessaging.identity(message, connection: connection)
        let reply = try await connection.call(["operation": "message-edit", "id": identity.sessionID, "eventID": identity.eventID, "text": String(content.characters)])
        _ = try SiriMessageReceipt.accepted(events: reply.events ?? [], requestID: String(identity.eventID.dropFirst(7)), text: String(content.characters))
        await SiriMessageMaintenance.update(host: connection.host, sessionID: identity.sessionID) {
            try await AutolithMessageContext.index((reply.events ?? []).compactMap { AutolithMessageEntity(event: $0, conversation: message.conversation) })
        }
        SiriInvocation.record("Messages: edited queued message")
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.unsendMessage)
struct UnsendAutolithMessageIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    var message: AutolithMessageEntity
    @MainActor func perform() async throws -> some IntentResult {
        let connection = try SiriSessionService.connected()
        let identity = try SiriMessaging.identity(message, connection: connection)
        let reply = try await connection.call(["operation": "message-unsend", "id": identity.sessionID, "eventID": identity.eventID])
        try SiriMessageReceipt.confirmed(reply.ok)
        await SiriMessageMaintenance.update(host: connection.host, sessionID: identity.sessionID) {
            try await AutolithConversationContext.index.deleteAppEntities(identifiedBy: [message.id, identity.id], ofType: AutolithMessageEntity.self)
        }
        SiriInvocation.record("Messages: unsent queued message")
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.setMessageReadStatus)
struct SetAutolithMessageReadStatusIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    var message: AutolithMessageEntity
    var isRead: Bool
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<AutolithMessageEntity> {
        let connection = try SiriSessionService.connected()
        let identity = try SiriMessaging.identity(message, connection: connection)
        let reply = try await connection.call(["operation": "message-read", "id": identity.sessionID, "eventID": identity.eventID, "isRead": isRead])
        try SiriMessageReceipt.confirmed(reply.ok)
        let updated = message; updated.isRead = isRead
        await SiriMessageMaintenance.update(host: connection.host, sessionID: identity.sessionID) {
            try await AutolithMessageContext.index([updated])
        }
        SiriInvocation.record("Messages: read status updated")
        return .result(value: updated)
    }
}
