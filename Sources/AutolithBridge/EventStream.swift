import Foundation
import BridgeCore
import CoreFoundation

/// A single authenticated subscription. All mutable state belongs to the listener queue.
final class EventStream {
    private let connection: BridgeConnection
    private let queue: DispatchQueue
    private let backend: BackendPool
    private let onClose: () -> Void
    private let receiptRevision: () -> String
    private var decoder = WebSocketDecoder(maximumMessageBytes: 8192)
    private var pollTimer: DispatchSourceTimer?
    private var pollInFlight = false
    private var timer: DispatchSourceTimer?
    private var subscribed = false
    private var closed = false
    private var closing = false
    private var pendingBytes = 0
    private var receivedEnvelope = false
    private var lastPong = DispatchTime.now().uptimeNanoseconds
    private var sessionID = ""
    private var epoch = ""
    private var sequence = 0

    init(connection: BridgeConnection, queue: DispatchQueue, backend: BackendPool,
         receiptRevision: @escaping () -> String = { "" }, onClose: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.backend = backend; self.onClose = onClose
        self.receiptRevision = receiptRevision
    }

    func start(response: Data, remainder: Data) {
        send(response)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closing else { return }
            if DispatchTime.now().uptimeNanoseconds - self.lastPong > 45_000_000_000 {
                self.stop(); return
            }
            self.send(try! WebSocketEncoder.ping(Data("autolith".utf8)))
        }
        self.timer = timer; timer.resume()
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.subscribed else { return }
            self.fail("Subscribe within 10 seconds.")
        }
        if !remainder.isEmpty { consume(remainder) }
        receive()
    }

    private func receive() {
        guard !closing else { return }
        connection.receive { [self] data, ended, error in
            guard !closing else { return }
            if let data { consume(data) }
            if ended || error != nil { stop() } else { receive() }
        }
    }

    private func consume(_ data: Data) {
        do {
            for event in try decoder.receive(data) {
                guard !closing else { return }
                switch event {
                case .text(let text):
                    guard !subscribed else { fail("One subscription is allowed per connection."); return }
                    try subscribe(text)
                case .ping(let payload): send(try WebSocketEncoder.pong(payload))
                case .pong(let payload):
                    if payload == Data("autolith".utf8) { lastPong = DispatchTime.now().uptimeNanoseconds }
                case .close(let code, let reason): finish(code: code ?? 1000, reason: reason)
                }
            }
        } catch { fail("Invalid event stream request.") }
    }

    static func subscription(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["operation"] as? String == "subscribe",
              let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= 1024 else {
            throw BridgeError.invalid("Invalid subscription")
        }
        if let epoch = object["epoch"], !(epoch is String) { throw BridgeError.invalid("Invalid epoch") }
        if let after = object["after"] {
            guard let number = after as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
                  number.doubleValue.rounded(.down) == number.doubleValue else { throw BridgeError.invalid("Invalid cursor") }
        }
        return object
    }

    private func subscribe(_ text: String) throws {
        let object = try Self.subscription(text)
        sessionID = object["id"] as! String
        epoch = object["epoch"] as? String ?? ""
        subscribed = true
        epoch = UUID().uuidString
        let pollTimer = DispatchSource.makeTimerSource(queue: queue)
        pollTimer.schedule(deadline: .now(), repeating: 2)
        pollTimer.setEventHandler { [weak self] in self?.poll() }
        self.pollTimer = pollTimer
        pollTimer.resume()
    }

    private var pollContext: BackendRequestContext?
    private func poll() {
        guard !closing, !pollInFlight else { return }
        pollInFlight = true
        let context = BackendRequestContext()
        pollContext = context
        let id = sessionID
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let result: Result<[String: Any], Error> = Result {
                var snapshot = try self.backend.watchSnapshot(id, context: context)
                snapshot["transcriptRevision"] = (snapshot["transcriptRevision"] as? String ?? "") + ":" + self.receiptRevision()
                return snapshot
            }
            self.queue.async {
                self.pollInFlight = false
                self.pollContext = nil
                guard !self.closing else { return }
                switch result {
                case .success(let snapshot):
                    let envelope: [String: Any] = ["version": 1, "type": "snapshot", "sessionID": id,
                        "epoch": self.epoch, "sequence": self.sequence + 1, "status": snapshot["status"]!, "activity": [],
                        "transcriptRevision": snapshot["transcriptRevision"]!]
                    do { self.consumeLine(try JSONSerialization.data(withJSONObject: envelope)) }
                    catch { self.fail("Could not encode session status.") }
                case .failure(let error): self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func consumeLine(_ line: Data) {
        guard !closing else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            fail("Invalid backend stream output.")
            return
        }
        guard let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let type = object["type"] as? String, ["snapshot", "event", "error"].contains(type),
              let text = String(data: line, encoding: .utf8) else {
            if let error = object["error"] as? String { fail(error) }
            else { fail("Unsupported backend event envelope.") }
            return
        }
        guard object["sessionID"] as? String == sessionID else { fail("Backend event belongs to another session."); return }
        if type != "error" {
            guard let nextEpoch = object["epoch"] as? String, !nextEpoch.isEmpty, nextEpoch.utf8.count <= 256,
                  let number = object["sequence"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let nextSequence = Int(number.stringValue), nextSequence >= 0 else {
                fail("Invalid backend event cursor."); return
            }
            if type == "event" {
                guard receivedEnvelope, nextEpoch == epoch, sequence < Int.max, nextSequence == sequence + 1,
                      object["kind"] is String, object["payload"] is [String: Any] else {
                    fail("Backend event sequence is out of order."); return
                }
            } else {
                guard let status = object["status"] as? [String: Any], status["id"] as? String == sessionID,
                      object["activity"] is [[String: Any]] else { fail("Invalid backend snapshot."); return }
            }
            epoch = nextEpoch
            sequence = nextSequence
        }
        receivedEnvelope = true
        send(WebSocketEncoder.text(text))
        if type == "error" { finish(code: 1011, reason: "Backend stream error") }
    }

    private func send(_ data: Data) {
        guard !closed else { return }
        guard pendingBytes + data.count <= 2_097_152 else { stop(); return }
        pendingBytes += data.count
        connection.send(data) { [self] error in
            pendingBytes -= data.count
            if error != nil || (closing && pendingBytes == 0) { stop() }
        }
    }

    private func fail(_ message: String) {
        guard !closing else { return }
        let object: [String: Any] = ["version": 1, "type": "error", "sessionID": sessionID,
                                     "epoch": epoch, "sequence": sequence, "error": String(message.prefix(4096))]
        if let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) {
            send(WebSocketEncoder.text(text))
        }
        finish(code: 1011, reason: "Event stream failed")
    }

    private func finish(code: UInt16, reason: String) {
        guard !closing else { return }
        closing = true
        stopPolling()
        timer?.cancel(); timer = nil
        if let frame = try? WebSocketEncoder.close(code: code, reason: reason) { send(frame) }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.stop() }
    }

    private func stopPolling() {
        pollTimer?.cancel(); pollTimer = nil
        pollContext?.cancel(); pollContext = nil
    }

    func stop() {
        guard !closed else { return }
        closed = true; closing = true
        timer?.cancel(); timer = nil
        stopPolling()
        connection.cancel()
        onClose()
    }
}
