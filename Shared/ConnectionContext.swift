import Foundation

/// Capture once before suspension. Never resolve a pending request against new credentials.
struct ConnectionContext: Equatable, Sendable {
    let host: String
    let token: String
    let generation: Int

    func endpoint() throws -> URL {
        let address = try CompanionEndpoint.canonical(host)
        guard !token.isEmpty, let url = URL(string: address) else { throw URLError(.userAuthenticationRequired) }
        return url.appendingPathComponent("rpc")
    }
}

/// A candidate probe must finish successfully against the same active identity.
/// The caller performs all persistent writes after this boundary.
@MainActor enum ConnectionCandidateProbe {
    static func validate(previous: ConnectionContext, candidate: ConnectionContext,
                         current: () -> ConnectionContext,
                         probe: (ConnectionContext) async throws -> Void) async throws {
        _ = try candidate.endpoint()
        try await probe(candidate)
        try Task.checkCancellation()
        guard current() == previous else { throw CancellationError() }
    }
}

struct ConnectionCallbackLease: Sendable {
    let context: ConnectionContext
    let epoch: UUID
    func accepts(current: ConnectionContext, epoch: UUID) -> Bool {
        self.context == current && self.epoch == epoch
    }
}

/// Limits apply to decoded HTTP bytes, including chunked and compressed responses.
enum BoundedHTTP {
    static func limit(operation: String) -> Int {
        switch operation {
        case "transcript", "transcript-sync", "message-events": return 8 * 1024 * 1024
        case "list", "catalog", "browse": return 2 * 1024 * 1024
        default: return 256 * 1024
        }
    }

    static func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var accumulator = ResponseAccumulator(limit: limit)
        try accumulator.validate(expectedLength: response.expectedContentLength)
        for try await byte in bytes {
            try Task.checkCancellation()
            try accumulator.append(byte)
        }
        return (accumulator.data, http)
    }
}

struct ResponseAccumulator {
    let limit: Int
    private(set) var data = Data()
    func validate(expectedLength: Int64) throws {
        guard expectedLength <= Int64(limit) else { throw URLError(.dataLengthExceedsMaximum) }
    }
    mutating func append(_ byte: UInt8) throws {
        guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
        data.append(byte)
    }
}
