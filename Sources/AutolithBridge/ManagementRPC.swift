import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import BridgeCore

/// The deliberately small readable-data subset used by the management protocol.
indirect enum ManagementForm: Equatable {
    case atom(String), string(String), list([ManagementForm])

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var list: [ManagementForm]? { if case .list(let value) = self { return value }; return nil }
    func field(_ name: String) -> ManagementForm? {
        guard let values = list, values.count % 2 == 1 else { return nil }
        var found: ManagementForm?
        for index in stride(from: 1, to: values.count, by: 2) where values[index] == .atom(name) {
            guard found == nil else { return nil }
            found = values[index + 1]
        }
        return found
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func parse(_ data: Data) throws -> ManagementForm {
        guard let text = String(data: data, encoding: .utf8), data.count <= 33_554_432 else {
            throw BridgeError.invalid("Invalid management frame encoding or size.")
        }
        let characters = Array(text)
        var index = 0, nodes = 0
        func whitespace() { while index < characters.count && [" ", "\n", "\r", "\t"].contains(characters[index]) { index += 1 } }
        func read(_ depth: Int) throws -> ManagementForm {
            nodes += 1; whitespace()
            guard depth < 32, nodes <= 65536, index < characters.count else { throw BridgeError.invalid("Invalid management form.") }
            let character = characters[index]; index += 1
            if character == "#" {
                // SBCL prints some simple strings readably as typed arrays.
                guard index < characters.count, ["a", "A"].contains(characters[index]) else {
                    throw BridgeError.invalid("Unsupported management reader syntax.")
                }
                index += 1; whitespace()
                guard index < characters.count, characters[index] == "(" else { throw BridgeError.invalid("Invalid management string array.") }
                index += 1
                let dimensions = try read(depth + 1), elementType = try read(depth + 1)
                whitespace()
                guard index < characters.count, characters[index] == "." else { throw BridgeError.invalid("Invalid management string array.") }
                index += 1
                let content = try read(depth + 1)
                whitespace()
                guard index < characters.count, characters[index] == ")",
                      let shape = dimensions.list, shape.count == 1,
                      case .atom(let dimension) = shape[0], let count = Int(dimension),
                      [.atom("base-char"), .atom("character")].contains(elementType),
                      let value = content.string, value.unicodeScalars.count == count else {
                    throw BridgeError.invalid("Invalid management string array.")
                }
                index += 1
                return .string(value)
            }
            if character == "(" {
                var values: [ManagementForm] = []
                while true {
                    whitespace()
                    guard index < characters.count else { throw BridgeError.invalid("Unclosed management form.") }
                    if characters[index] == ")" { index += 1; return .list(values) }
                    values.append(try read(depth + 1))
                }
            }
            if character == "\"" {
                var value = ""
                while index < characters.count {
                    let next = characters[index]; index += 1
                    if next == "\"" { return .string(value) }
                    if next == "\\" {
                        guard index < characters.count else { break }
                        value.append(characters[index]); index += 1
                    } else { value.append(next) }
                }
                throw BridgeError.invalid("Unclosed management string.")
            }
            var atom = String(character)
            while index < characters.count && ![" ", "\n", "\r", "\t", "(", ")"].contains(characters[index]) {
                atom.append(characters[index]); index += 1
            }
            guard atom.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: ":abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-+").contains($0) }) else {
                throw BridgeError.invalid("Unsupported management syntax.")
            }
            return .atom(atom.lowercased())
        }
        let result = try read(0); whitespace()
        guard index == characters.count else { throw BridgeError.invalid("Trailing management forms.") }
        return result
    }
}

/// One serial HMAC-authenticated Unix connection. A failed evaluation is never replayed.
final class ManagementRPC {
    let socketPath: String
    let tokenPath: String
    private var descriptor: Int32 = -1
    private let timeout: TimeInterval
    // BackendPool serializes access, including this evaluation's shared budget.
    private var context = BackendRequestContext()

    init(socketPath: String, tokenPath: String, timeout: TimeInterval = 60) {
        self.socketPath = socketPath; self.tokenPath = tokenPath; self.timeout = timeout
    }
    deinit { disconnect() }
    private func disconnect() { if descriptor >= 0 { close(descriptor); descriptor = -1 } }

    func evaluate(_ source: String, context: BackendRequestContext = BackendRequestContext()) throws -> [String] {
        self.context = context
        guard source.utf8.count <= 262144 else { throw BridgeError.invalid("Management source exceeds the size limit.") }
        do {
            try context.check()
            let deadline = ProcessInfo.processInfo.systemUptime + min(timeout, context.remaining)
            // An idle server may close its stream. Reconnect only when EOF is
            // established before any bytes of this evaluation are sent.
            if descriptor >= 0 {
                var byte: UInt8 = 0
                let count = recv(descriptor, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
                if count == 0 { disconnect() }
                else if count > 0 { throw BridgeError.invalid("Unexpected data on idle management connection.") }
            }
            if descriptor < 0 { try connect(deadline: deadline) }
            try send("(:evaluate :source \(ManagementForm.quote(source)))", deadline: deadline)
            let reply = try receive(deadline: deadline)
            guard reply.list?.first == .atom(":evaluation-result") else { throw BridgeError.invalid("Invalid management evaluation response.") }
            guard reply.field(":status") == .atom(":ok") else {
                throw BridgeError.invalid(reply.field(":report")?.string ?? "Management evaluation failed. Check the session before retrying a mutation.")
            }
            guard reply.field(":values-truncated-p") == .atom("nil"), reply.field(":output-truncated-p") == .atom("nil") else {
                throw BridgeError.invalid("Management output was truncated. Check the session before retrying a mutation.")
            }
            let values = reply.field(":values")
            if values == .atom("nil") { return [] }
            guard let forms = values?.list, forms.allSatisfy({ $0.string != nil }) else { throw BridgeError.invalid("Invalid management values.") }
            return forms.compactMap(\.string)
        } catch { disconnect(); throw error }
    }

    private func connect(deadline: TimeInterval) throws {
        var address = sockaddr_un()
        let bytes = Array(socketPath.utf8) + [0]
        guard !socketPath.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BridgeError.invalid("Management socket path is too long or invalid.")
        }
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_mode & 0o7777 == 0o600 else {
            throw BridgeError.invalid("Management socket must be owned by you with mode 0600. Enable Autolith's management REPL first.")
        }
        #if canImport(Darwin)
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        descriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw BridgeError.invalid("Cannot create management socket.") }
        #if canImport(Darwin)
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw BridgeError.invalid("Cannot configure management socket.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw BridgeError.invalid("Cannot configure management socket.") }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Glibc.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw BridgeError.invalid("Cannot connect to Autolith management RPC.") }
            try wait(POLLOUT, deadline: deadline)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw BridgeError.invalid("Management connection failed.") }
        }
        #if canImport(Darwin)
        var peerUser: uid_t = 0, peerGroup: gid_t = 0
        guard getpeereid(descriptor, &peerUser, &peerGroup) == 0, peerUser == getuid() else {
            throw BridgeError.invalid("Management socket belongs to another user.")
        }
        #else
        // Linux SO_PEERCRED returns struct ucred: pid, uid, gid.
        struct PeerCredentials { var pid: pid_t = 0; var uid: uid_t = 0; var gid: gid_t = 0 }
        var peer = PeerCredentials()
        var peerSize = socklen_t(MemoryLayout<PeerCredentials>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &peer, &peerSize) == 0,
              peerSize == socklen_t(MemoryLayout<PeerCredentials>.size), peer.uid == getuid() else {
            throw BridgeError.invalid("Management socket belongs to another user.")
        }
        #endif
        let challenge = try receive(deadline: deadline)
        guard challenge.list?.first == .atom(":challenge"), challenge.field(":version") == .atom("1"),
              challenge.field(":algorithm") == .atom(":hmac-sha-256"),
              let nonce = challenge.field(":nonce")?.string, nonce.utf8.count == 64 else {
            throw BridgeError.invalid("Unsupported management authentication challenge.")
        }
        let hex = Array(nonce.utf8)
        var nonceBytes = Data()
        for index in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(decoding: hex[index...index+1], as: UTF8.self), radix: 16) else { throw BridgeError.invalid("Invalid management nonce.") }
            nonceBytes.append(byte)
        }
        var token = try Self.readToken(tokenPath)
        defer { token.resetBytes(in: 0..<token.count) }
        let proof = HMAC<SHA256>.authenticationCode(for: nonceBytes, using: SymmetricKey(data: token)).map { String(format: "%02x", $0) }.joined()
        try send("(:authenticate :proof \(ManagementForm.quote(proof)))", deadline: deadline)
        guard try receive(deadline: deadline) == .list([.atom(":authenticated"), .atom(":version"), .atom("1")]) else {
            throw BridgeError.invalid("Management authentication failed.")
        }
    }

    static func readToken(_ path: String) throws -> Data {
        guard !path.utf8.contains(0) else { throw BridgeError.invalid("Invalid management token path.") }
        let file = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw BridgeError.invalid("Cannot open management token file.") }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o7777 == 0o600, metadata.st_size > 0, metadata.st_size <= 4096 else {
            throw BridgeError.invalid("Management token must be a regular file owned by you, mode 0600, containing 1 to 4096 bytes.")
        }
        var bytes = [UInt8](repeating: 0, count: 4097)
        defer { for index in bytes.indices { bytes[index] = 0 } }
        var count = 0
        while count < bytes.count {
            let size = bytes.withUnsafeMutableBytes {
                #if canImport(Darwin)
                Darwin.read(file, $0.baseAddress!.advanced(by: count), $0.count - count)
                #else
                Glibc.read(file, $0.baseAddress!.advanced(by: count), $0.count - count)
                #endif
            }
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw BridgeError.invalid("Cannot read management token.") }
            if size == 0 { break }; count += size
        }
        guard count > 0 && count <= 4096 else { throw BridgeError.invalid("Invalid management token size.") }
        return Data(bytes.prefix(count))
    }

    private func wait(_ events: Int32, deadline: TimeInterval) throws {
        while true {
            try context.check()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw BridgeError.invalid("Management RPC timed out. Check the session before retrying a mutation.") }
            var entry = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let result = poll(&entry, 1, Int32(min(remaining * 1000, 50)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw BridgeError.invalid("Management socket failed.") }
            if result > 0 { try context.check(); return }
        }
    }
    private func send(_ text: String, deadline: TimeInterval) throws {
        let body = Data(text.utf8), size = UInt32(body.count)
        var packet = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        packet.append(body)
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(POLLOUT, deadline: deadline)
                let count = try context.whileActive {
                    #if canImport(Darwin)
                    Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    #else
                    Glibc.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                    #endif
                }
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw BridgeError.invalid("Management RPC disconnected. Check the session before retrying a mutation.") }
                offset += count
            }
        }
    }
    private func read(_ count: Int, deadline: TimeInterval) throws -> Data {
        var data = Data(count: count), offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < count {
                try wait(POLLIN, deadline: deadline)
                #if canImport(Darwin)
                let received = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                #else
                let received = Glibc.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                #endif
                if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard received > 0 else { throw BridgeError.invalid("Management RPC disconnected. Check the session before retrying a mutation.") }
                offset += received
            }
        }
        return data
    }
    private func receive(deadline: TimeInterval) throws -> ManagementForm {
        let size = try read(4, deadline: deadline).reduce(0) { $0 * 256 + Int($1) }
        guard size > 0 && size <= 33_554_432 else { throw BridgeError.invalid("Invalid management frame size.") }
        return try ManagementForm.parse(read(size, deadline: deadline))
    }
}
