import Foundation

struct SessionStreamCursor: Equatable, Sendable {
    let epoch: String
    let sequence: Int
}

enum SessionStreamError: LocalizedError {
    case invalidEnvelope, sequenceGap, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidEnvelope: "Invalid live activity message."
        case .sequenceGap: "Live activity lost its place. Requesting a snapshot."
        case .server(let message): message
        }
    }
}

/// Ephemeral activity is separate from the durable HTTP transcript.
struct SessionStream: Sendable {
    struct Envelope: Decodable {
        struct Payload: Decodable { var event: Event?; var status: Session? }
        let version: Int
        let type: String
        let sessionID: String
        var epoch: String?
        var sequence: Int?
        var status: Session?
        var activity: [Event]?
        var kind: String?
        var payload: Payload?
        var error: String?
        var transcriptRevision: String?
    }
    let sessionID: String
    private(set) var cursor: SessionStreamCursor?
    private(set) var activity: [Event] = []
    private(set) var status: Session?
    private(set) var transcriptChanged = false
    private(set) var statusChanged = false
    private(set) var activityChanged = false
    private var transcriptRevision: String?

    mutating func receive(_ data: Data) throws -> Bool {
        transcriptChanged = false
        statusChanged = false
        activityChanged = false
        guard data.count <= 1_048_576 else { throw SessionStreamError.invalidEnvelope }
        let message = try JSONDecoder().decode(Envelope.self, from: data)
        guard message.version == 1, message.sessionID == sessionID else { throw SessionStreamError.invalidEnvelope }
        if message.type == "error" { throw SessionStreamError.server(message.error ?? "Stream rejected.") }
        guard let epoch = message.epoch, !epoch.isEmpty, let sequence = message.sequence, sequence >= 0,
              message.status == nil || message.status?.id == sessionID,
              message.payload?.status == nil || message.payload?.status?.id == sessionID else {
            throw SessionStreamError.invalidEnvelope
        }
        if message.type == "snapshot" {
            guard let status = message.status, let activity = message.activity else { throw SessionStreamError.invalidEnvelope }
            statusChanged = self.status != status
            self.status = status
            activityChanged = true
            self.activity = []
            for event in activity { upsert(event) }
            transcriptChanged = cursor?.epoch != epoch || message.transcriptRevision == nil
                || transcriptRevision != message.transcriptRevision
            transcriptRevision = message.transcriptRevision
        } else if message.type == "event" {
            guard let cursor, cursor.epoch == epoch else { return try resnapshot() }
            if sequence <= cursor.sequence { return false }
            guard cursor.sequence < Int.max, sequence == cursor.sequence + 1 else { return try resnapshot() }
            guard message.kind != nil else { throw SessionStreamError.invalidEnvelope }
            if let status = message.payload?.status { self.status = status; statusChanged = true }
            if let event = message.payload?.event { upsert(event); activityChanged = true }
            transcriptChanged = message.kind == "transcript-changed"
        } else { throw SessionStreamError.invalidEnvelope }
        cursor = SessionStreamCursor(epoch: epoch, sequence: sequence)
        return true
    }

    private mutating func resnapshot() throws -> Bool {
        cursor = nil
        activity = []
        throw SessionStreamError.sequenceGap
    }

    private mutating func upsert(_ event: Event) {
        let text = String(decoding: event.text.utf8.prefix(65_536), as: UTF8.self)
        let bounded = Event(id: event.id, role: event.role, tool: event.tool, text: text, timestamp: event.timestamp)
        activity.removeAll { $0.id == event.id }
        activity.append(bounded)
        while activity.count > 200 || activity.reduce(0, { $0 + $1.text.utf8.count + $1.id.utf8.count + $1.role.utf8.count + $1.tool.utf8.count }) > 1_048_576 {
            activity.removeFirst()
        }
    }
}
