import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
public enum BoundedHTTP {
    static func limit(operation: String) -> Int {
        switch operation {
        case "transcript", "transcript-sync", "message-events": return 8 * 1024 * 1024
        case "list", "catalog", "browse": return 2 * 1024 * 1024
        default: return 256 * 1024
        }
    }

    public static func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let transfer = BoundedHTTPTransfer(limit: limit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                transfer.start(request, continuation: continuation)
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            transfer.cancel()
        }
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
    mutating func append(_ chunk: Data) throws {
        guard data.count <= limit, chunk.count <= limit - data.count else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        data.append(chunk)
    }
}

/// URLSession delivers decoded chunks here, without collecting an unbounded response first.
/// The lock also covers cancellation, which can arrive outside the serial delegate queue.
private final class BoundedHTTPTransfer: @unchecked Sendable {
    private typealias Reply = (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var accumulator: ResponseAccumulator
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<Reply, Error>?
    private var task: URLSessionDataTask?
    private var finished = false

    init(limit: Int) {
        accumulator = ResponseAccumulator(limit: limit)
    }

    func start(_ request: URLRequest, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let task = BoundedHTTPTransport.shared.task(request, transfer: self)
        self.task = task
        // Resume under the lock so cancellation cannot precede task registration.
        task.resume()
        lock.unlock()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Reply, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let task = self.task
        self.continuation = nil
        self.task = nil
        lock.unlock()
        if let task {
            BoundedHTTPTransport.shared.remove(task)
            task.cancel()
        }
        continuation?.resume(with: result)
    }

    func receive(_ response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); completionHandler(.cancel); return }
        do {
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            try accumulator.validate(expectedLength: response.expectedContentLength)
            self.response = http
            lock.unlock()
            completionHandler(.allow)
        } catch {
            lock.unlock()
            finish(.failure(error))
            completionHandler(.cancel)
        }
    }

    func receive(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        do {
            try accumulator.append(data)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(.failure(error))
        }
    }

    func complete(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let result: Result<Reply, Error>
        if let error {
            result = .failure(error)
        } else if let response {
            result = .success((accumulator.data, response))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        lock.unlock()
        finish(result)
    }
}

/// Reuse connections while keeping credentials, byte limits, and cancellation per request.
private final class BoundedHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BoundedHTTPTransport()
    private let lock = NSLock()
    private var transfers: [Int: BoundedHTTPTransfer] = [:]
    private var session: URLSession!

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func task(_ request: URLRequest, transfer: BoundedHTTPTransfer) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock(); transfers[task.taskIdentifier] = transfer; lock.unlock()
        return task
    }

    func remove(_ task: URLSessionTask) {
        lock.lock(); transfers[task.taskIdentifier] = nil; lock.unlock()
    }

    private func transfer(_ task: URLSessionTask) -> BoundedHTTPTransfer? {
        lock.lock(); defer { lock.unlock() }
        return transfers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(dataTask) else { completionHandler(.cancel); return }
        transfer.receive(response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(dataTask)?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(task)?.complete(error)
    }

    // Never forward a bearer token through a redirect or silently replay a command.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
