import Foundation

enum SiriConversationMemory {
    static func sent(id: String, host: String, defaults: UserDefaults = .standard) {
        CompanionEndpoint.migratePreferences(defaults: defaults)
        defaults.set(id, forKey: "siriLastSentSession:" + CompanionEndpoint.key(host))
        remember(id: id, host: host, defaults: defaults)
    }
    static func lastSentIdentifier(host: String, defaults: UserDefaults = .standard) -> String? {
        CompanionEndpoint.migratePreferences(defaults: defaults)
        return defaults.string(forKey: "siriLastSentSession:" + CompanionEndpoint.key(host))
    }
    static func remember(id: String, host: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: "siriLatestSessionID")
        defaults.set(CompanionEndpoint.key(host), forKey: "siriLatestSessionHost")
    }
    static func identifier(host: String, defaults: UserDefaults = .standard) -> String? {
        guard let rememberedHost = defaults.string(forKey: "siriLatestSessionHost"),
              CompanionEndpoint.key(rememberedHost) == CompanionEndpoint.key(host) else { return nil }
        return defaults.string(forKey: "siriLatestSessionID")
    }
}

@MainActor enum SiriFollowUp {
    enum Failure: LocalizedError {
        case resumeUnconfirmed(String)
        case wrongConversation
        case deliveryUnconfirmed(String)
        var errorDescription: String? {
            switch self {
            case .resumeUnconfirmed(let id): "Could not confirm that conversation \(id) resumed. Check it in Autolith before retrying."
            case .wrongConversation: "The computer returned a different conversation while resuming. No follow-up was sent."
            case .deliveryUnconfirmed(let id): "Could not confirm delivery to conversation \(id). Check it in Autolith before sending the follow-up again."
            }
        }
    }
    static func send(question: String, session: Session, call: ([String: String]) async throws -> String?) async throws {
        let message = try SiriContent.question(question)
        if !session.isRunning {
            let resumed: String?
            do { resumed = try await call(["operation": "resume", "id": session.id, "workspace": session.workspace, "permissions": "ask"]) }
            catch { throw Failure.resumeUnconfirmed(session.id) }
            guard resumed == session.id else { throw Failure.wrongConversation }
        }
        do { _ = try await call(["operation": "tell", "id": session.id, "message": message]) }
        catch { throw Failure.deliveryUnconfirmed(session.id) }
    }
}
