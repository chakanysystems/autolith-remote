import Foundation
import Darwin
import BridgeCore

/// Bounded, serial request streams. Never replay a request after an uncertain failure.
final class BackendPool: @unchecked Sendable {
    private let condition = NSCondition()
    private var idle: [BackendWorker] = []
    private var count = 0
    private let executable: String
    init(executable: String) { self.executable = executable }

    func call(_ request: Data) throws -> Data {
        condition.lock()
        while idle.isEmpty && count == 4 { condition.wait() }
        let worker: BackendWorker
        if let existing = idle.popLast() { worker = existing }
        else { worker = BackendWorker(executable: executable); count += 1 }
        condition.unlock()
        defer { condition.lock(); idle.append(worker); condition.signal(); condition.unlock() }
        return try worker.call(request)
    }
}

private final class BackendWorker {
    private let executable: String
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffered = Data()
    init(executable: String) { self.executable = executable }
    deinit { stop() }

    private func stop() {
        try? input?.close(); try? output?.close()
        if let process, process.isRunning {
            let pid = process.processIdentifier
            // Foundation launches a separate process group. Include launcher children,
            // such as Nix image builders, when abandoning an uncertain request.
            let ownsGroup = getpgid(pid) == pid && pid != getpgrp()
            if ownsGroup { kill(-pid, SIGTERM) } else { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if ownsGroup { kill(-pid, SIGKILL) }
                else if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        input = nil; output = nil; process = nil; buffered.removeAll()
    }

    func call(_ request: Data) throws -> Data {
        do {
            if process?.isRunning != true {
                stop()
                let child = Process(), stdin = Pipe(), stdout = Pipe()
                child.executableURL = URL(fileURLWithPath: executable)
                child.arguments = ["mobile"]
                child.standardInput = stdin; child.standardOutput = stdout
                child.standardError = FileHandle.standardError
                try child.run()
                process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
                let descriptor = stdin.fileHandleForWriting.fileDescriptor
                guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1,
                      fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else { throw BridgeError.invalid("Cannot configure backend pipe.") }
                let handshake = try exchange(Data(#"{"operation":"rpc-handshake"}"#.utf8), allowPreamble: true)
                guard let value = try JSONSerialization.jsonObject(with: handshake) as? [String: Any], value["rpcProtocol"] as? Int == 1 else {
                    throw BridgeError.invalid("Update the Mac backend: persistent mobile RPC is required.")
                }
            }
            return try exchange(request, allowPreamble: false)
        } catch { stop(); throw error }
    }

    private func exchange(_ request: Data, allowPreamble: Bool) throws -> Data {
        guard request.count <= 262144, let input, let output else { throw BridgeError.invalid("Invalid backend request.") }
        let deadline = Date().addingTimeInterval(60)
        let payload = request + Data([10])
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard deadline.timeIntervalSinceNow > 0 else { throw BridgeError.invalid("Backend request timed out. Check the conversation before retrying a mutation.") }
                var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 1000)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { throw BridgeError.invalid("Backend request failed.") }
                if ready == 0 { continue }
                let written = Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard written > 0 else { throw BridgeError.invalid("Backend disconnected. Check the conversation before retrying a mutation.") }
                offset += written
            }
        }
        var preamble = 0
        while true {
            if let newline = buffered.firstIndex(of: 10) {
                let line = Data(buffered[..<newline]); buffered.removeSubrange(...newline)
                guard line.count <= 8_000_000 else { throw BridgeError.invalid("Backend response exceeds the size limit.") }
                if (try? JSONSerialization.jsonObject(with: line)) != nil { return line }
                preamble += line.count + 1
                guard allowPreamble, preamble <= 65536 else { throw BridgeError.invalid("Invalid backend response.") }
                continue
            }
            guard buffered.count <= 8_000_000 else { throw BridgeError.invalid("Backend response exceeds the size limit.") }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw BridgeError.invalid("Autolith timed out. Check the conversation before retrying a mutation.") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw BridgeError.invalid("Backend response failed.") }
            if result == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let length = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if length < 0 && errno == EINTR { continue }
            guard length > 0 else { throw BridgeError.invalid("Backend disconnected. Check the conversation before retrying a mutation.") }
            buffered.append(contentsOf: bytes.prefix(length))
        }
    }
}
