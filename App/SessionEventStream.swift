import Foundation

/// A foreground-only subscription. Each attempt owns one socket and one heartbeat.
@MainActor enum SessionEventStream {
    static func run(endpoint: URL, token: String, sessionID: String,
                    cursor: @escaping () -> SessionStreamCursor?,
                    receive: @escaping (Data) async throws -> Void,
                    state: @escaping (String) -> Void) async {
        var delay = 1.0
        while !Task.isCancelled {
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            let session = URLSession(configuration: .ephemeral)
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 1_048_576
            state("Connecting live activity…")
            socket.resume()
            do {
                try await withTaskCancellationHandler {
                    var subscription: [String: Any] = ["operation": "subscribe", "id": sessionID]
                    if let cursor = cursor() {
                        subscription["epoch"] = cursor.epoch
                        subscription["after"] = cursor.sequence
                    }
                    let body = try JSONSerialization.data(withJSONObject: subscription)
                    try await socket.send(.string(String(decoding: body, as: UTF8.self)))
                    // Closing the socket releases receive() even on a half-open connection.
                    let heartbeat = Task {
                        do {
                            while !Task.isCancelled {
                                try await Task.sleep(for: .seconds(20))
                                let deadline = Task {
                                    do { try await Task.sleep(for: .seconds(10)); socket.cancel(with: .goingAway, reason: nil) }
                                    catch { }
                                }
                                socket.sendPing { error in
                                    deadline.cancel()
                                    if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                                }
                            }
                        } catch {
                            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
                        }
                    }
                    defer { heartbeat.cancel() }
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: throw SessionStreamError.invalidEnvelope
                        }
                        try await receive(data)
                        state("Live activity connected")
                        delay = 1
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                if !Task.isCancelled { state("Live activity disconnected: \(error.localizedDescription)") }
            }
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            guard !Task.isCancelled else { break }
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            delay = min(30, delay * 2)
        }
    }
}
