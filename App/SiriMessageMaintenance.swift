import AppIntents
import CoreSpotlight
import Foundation

@available(iOS 27.0, macOS 27.0, *)
@MainActor enum SiriMessageMaintenance {
    private static let key = "siriMessageIndexRepairs"

    /// Keep a repair request until a full transcript and conversation have been reindexed.
    static func update(host: String, sessionID: String, operation: () async throws -> Void) async {
        let id = SiriMessageIdentity(host: host, sessionID: sessionID, eventID: "repair").id
        var pending = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        pending[id] = UUID().uuidString
        UserDefaults.standard.set(pending, forKey: key)
        await SiriIndexMaintenance.run(update: operation) { error in
            UserDefaults.standard.set(error.localizedDescription, forKey: "siriContextError")
            SiriTrace.record("Message index: repair pending", sessionID: sessionID, errorCode: (error as NSError).code)
        }
    }

    static func repair(connection: Connection) async throws {
        let pending = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let host = connection.host
        for (id, revision) in pending {
            guard let identity = SiriMessageIdentity(id: id), identity.host == host else { continue }
            if let session = connection.sessions.first(where: { $0.id == identity.sessionID }) {
                let events = try await connection.call(["operation": "transcript", "id": session.id, "after": 0]).events ?? []
                guard connection.host == host else { return }
                // Refresh through the revision-aware path; do not overwrite a newer
                // cached history with this independent indexing request's response.
                await connection.loadTranscript(session.id)
                try await AutolithMessageContext.synchronize(host: host, sessions: connection.sessions, events: [session.id: events])
                try await AutolithConversationContext.indexEntities([AutolithConversationEntity(session: session, host: host, events: events)])
            }
            var current = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            if current[id] == revision { current.removeValue(forKey: id) }
            UserDefaults.standard.set(current, forKey: key)
        }
    }
}

@MainActor enum SiriMessageReading {
    static func read(_ event: Event, sessionID: String, connection: Connection) async throws -> Event {
        let host = connection.host
        let updated = try await SiriMessageReadState.markRead(event) {
            try await connection.call(["operation": "message-read", "id": sessionID, "eventID": event.id, "isRead": true]).ok
        }
        if #available(iOS 27.0, macOS 27.0, *), !event.hasBeenRead, updated.hasBeenRead {
            await SiriMessageMaintenance.update(host: host, sessionID: sessionID) { }
        }
        return updated
    }
}
