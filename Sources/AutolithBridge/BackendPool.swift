import Foundation
import Darwin
import CoreFoundation
import BridgeCore

/// Bounded serial streams. Never replay a request after an uncertain failure.
final class BackendPool: @unchecked Sendable {
    private let lock = NSLock()
    private let slots = DispatchSemaphore(value: 4)
    private var idle: [BackendWorker] = []
    private let executable: String
    init(executable: String) { self.executable = executable }

    /// Use the admission deadline for queueing, startup, handshake and user I/O.
    /// An expired queued request is never dispatched to the backend.
    func call(_ request: Data, deadline: DispatchTime = .now() + 60) throws -> Data {
        try call(request, context: BackendRequestContext(deadline: deadline))
    }

    func call(_ request: Data, context: BackendRequestContext) throws -> Data {
        while true {
            try context.check()
            if slots.wait(timeout: min(context.deadline, .now() + 0.05)) == .success { break }
        }
        defer { slots.signal() }
        try context.check()
        lock.lock()
        let worker = idle.popLast() ?? BackendWorker(executable: executable)
        lock.unlock()
        defer { lock.lock(); idle.append(worker); lock.unlock() }
        return try worker.call(request, context: context)
    }
}

private final class BackendWorker {
    private let executable: String
    private var child: BackendChild?
    private var buffered = Data()
    init(executable: String) { self.executable = executable }
    private func stop() { child?.stop(); child = nil; buffered.removeAll() }

    func call(_ request: Data, context: BackendRequestContext) throws -> Data {
        do {
            guard request.count <= 262144, !request.contains(10), !request.contains(13),
                  (try? JSONSerialization.jsonObject(with: request)) is [String: Any] else {
                throw BridgeError.invalid("Invalid backend request.")
            }
            try context.check()
            if child == nil {
                child = try BackendChild(executable: executable)
                let handshake = try exchange(Data(#"{"operation":"rpc-handshake"}"#.utf8), context: context, allowPreamble: true)
                guard let value = try JSONSerialization.jsonObject(with: handshake) as? [String: Any],
                      let version = value["rpcProtocol"] as? NSNumber,
                      CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1 else {
                    throw BridgeError.invalid("Update the Mac backend: persistent mobile RPC is required.")
                }
            }
            return try exchange(request, context: context, allowPreamble: false)
        } catch { stop(); throw error }
    }

    /// RPC v1 has no echoed correlation ID. Reject all observable surplus output,
    /// including partial lines, instead of assigning it to the next request. A
    /// late unsolicited response racing a new write still needs backend IDs.
    private func requireQuietOutput(_ output: Int32, context: BackendRequestContext) throws {
        var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
        var result: Int32
        repeat {
            try context.check()
            result = poll(&descriptor, 1, 0)
        } while result < 0 && errno == EINTR
        guard buffered.isEmpty, result == 0 else {
            throw BridgeError.invalid("Unsolicited backend output or disconnected protocol stream.")
        }
    }

    private func wait(_ fd: Int32, event: Int16, context: BackendRequestContext) throws {
        while true {
            try context.check()
            let remaining = context.remaining
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, min(remaining * 1000, 50))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw BridgeError.invalid("Backend pipe failed.") }
            if result > 0 { try context.check(); return }
        }
    }

    private func exchange(_ request: Data, context: BackendRequestContext, allowPreamble: Bool) throws -> Data {
        guard let child else { throw BridgeError.invalid("Backend unavailable.") }
        if !allowPreamble { try requireQuietOutput(child.output, context: context) }
        let payload = request + Data([10])
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(child.input, event: Int16(POLLOUT), context: context)
                let written = try context.whileActive {
                    Darwin.write(child.input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard written > 0 else { throw BridgeError.invalid("Backend disconnected. Check the conversation before retrying a mutation.") }
                offset += written
            }
        }
        var preamble = 0
        while true {
            try context.check()
            if let newline = buffered.firstIndex(of: 10) {
                let line = Data(buffered[..<newline]); buffered.removeSubrange(...newline)
                guard line.count <= 8_000_000 else { throw BridgeError.invalid("Backend response exceeds the size limit.") }
                if (try? JSONSerialization.jsonObject(with: line)) is [String: Any] {
                    // A hangup after a complete reply is valid, but extra bytes are not.
                    var byte: UInt8 = 0
                    var extra: Int
                    repeat {
                        try context.check()
                        extra = Darwin.read(child.output, &byte, 1)
                    } while extra < 0 && errno == EINTR
                    guard buffered.isEmpty, extra == 0 || (extra < 0 && errno == EAGAIN) else {
                        throw BridgeError.invalid("Unsolicited backend output.")
                    }
                    try context.check()
                    return line
                }
                preamble += line.count + 1
                guard allowPreamble, preamble <= 65536 else { throw BridgeError.invalid("Invalid backend response.") }
                continue
            }
            guard buffered.count <= 8_000_000 else { throw BridgeError.invalid("Backend response exceeds the size limit.") }
            try wait(child.output, event: Int16(POLLIN), context: context)
            var bytes = [UInt8](repeating: 0, count: 65536)
            let length = Darwin.read(child.output, &bytes, bytes.count)
            if length < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard length > 0 else { throw BridgeError.invalid("Backend disconnected. Check the conversation before retrying a mutation.") }
            buffered.append(contentsOf: bytes.prefix(length))
        }
    }
}
