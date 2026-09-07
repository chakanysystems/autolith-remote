import Foundation

struct SiriMessageIndexPlan: Sendable {
    struct Batch: Sendable {
        let session: Session
        let transcript: [Event]
        let changed: [Event]
        let byID: [String: Event]
    }
    let removed: [String]
    let batches: [Batch]

    init(host: String, sessions: [Session], events: [String: [Event]], known: [String],
         indexedEvents: [String: [String: Event]], indexedSessions: [String: Session]) {
        let validSessions = Set(sessions.map(\.id))
        let validEvents = events.mapValues { Set($0.filter { SiriMessageIdentity.date(for: $0) != nil }.map(\.id)) }
        removed = known.filter { id in
            guard let identity = SiriMessageIdentity(id: id) else { return true }
            if identity.id != id || identity.host != host || !validSessions.contains(identity.sessionID) { return true }
            if let identifiers = validEvents[identity.sessionID] { return !identifiers.contains(identity.eventID) }
            return false
        }
        batches = sessions.compactMap { session in
            guard let transcript = events[session.id] else { return nil }
            let key = host + "#" + session.id
            let previous = indexedSessions[key] == session ? indexedEvents[key] ?? [:] : [:]
            return Batch(session: session, transcript: transcript,
                         changed: transcript.filter { previous[$0.id] != $0 },
                         byID: Dictionary(transcript.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }))
        }
    }
}
