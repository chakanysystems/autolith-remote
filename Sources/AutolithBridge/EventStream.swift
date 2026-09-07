import Foundation
import Network
import BridgeCore
import CoreFoundation
import Darwin

/// A single authenticated subscription. All mutable state belongs to the listener queue.
final class EventStream {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let executable: String
    private let onClose: () -> Void
    private var decoder = WebSocketDecoder(maximumMessageBytes: 8192)
    private var process: Process?
    private var timer: DispatchSourceTimer?
    private var subscribed = false
    private var closed = false
    private var closing = false
    private var pendingBytes = 0
    private var lineBuffer = Data()
    private var preambleBytes = 0
    private var receivedEnvelope = false
    private var lastPong = DispatchTime.now().uptimeNanoseconds
    private var sessionID = ""
    private var epoch = ""
    private var sequence = 0

    init(connection: NWConnection, queue: DispatchQueue, executable: String, onClose: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.executable = executable; self.onClose = onClose
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, ended, error in
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
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["mobile"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        let request = try JSONSerialization.data(withJSONObject: object) + Data([10])
        DispatchQueue.global().async { [weak self] in
            do { try input.fileHandleForWriting.write(contentsOf: request); try input.fileHandleForWriting.close() }
            catch { self?.queue.async { [weak self] in self?.fail("Could not start subscription.") } }
        }
        // Synchronous handoff bounds data waiting outside the network send budget.
        DispatchQueue.global().async { [weak self] in
            defer { try? output.fileHandleForReading.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                // FileHandle.read(upToCount:) can wait to fill the buffer on pipes.
                // POSIX read returns available bytes without waiting for the next event.
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let data = Data(buffer.prefix(count))
                guard let self else { return }
                let keepReading = self.queue.sync { () -> Bool in
                    guard !self.closing else { return false }
                    self.consumeOutput(data)
                    return !self.closing
                }
                if !keepReading { return }
            }
            self?.queue.async { [weak self] in
                guard let self, !self.closing else { return }
                if !self.lineBuffer.isEmpty { self.consumeLine(self.lineBuffer); self.lineBuffer.removeAll() }
                if !self.receivedEnvelope { self.fail("Backend does not support event streaming.") }
                else { self.finish(code: 1000, reason: "Backend stream ended") }
            }
        }
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.receivedEnvelope else { return }
            self.fail("Backend did not start the event stream.")
        }
    }

    private func consumeOutput(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 10) {
            let line = Data(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            guard line.count <= 1_048_576 else { fail("Backend event exceeds the size limit."); return }
            consumeLine(line)
            if closing { return }
        }
        if lineBuffer.count > 1_048_576 { fail("Backend event exceeds the size limit.") }
    }

    private func consumeLine(_ line: Data) {
        guard !closing else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            preambleBytes += line.count + 1
            if receivedEnvelope || preambleBytes > 65536 { fail("Invalid backend stream output.") }
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
        connection.send(content: data, completion: .contentProcessed { [self] error in
            pendingBytes -= data.count
            if error != nil || (closing && pendingBytes == 0) { stop() }
        })
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
        stopProcess()
        timer?.cancel(); timer = nil
        if let frame = try? WebSocketEncoder.close(code: code, reason: reason) { send(frame) }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.stop() }
    }

    private func stopProcess() {
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            process.terminate()
            queue.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    func stop() {
        guard !closed else { return }
        closed = true; closing = true
        timer?.cancel(); timer = nil
        stopProcess()
        connection.cancel()
        onClose()
    }
}
