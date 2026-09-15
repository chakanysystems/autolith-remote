import Foundation
import XCTest
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
@testable import AutolithBridge

final class ManagementTestServer {
        let directory: URL
        let listener: Int32
        let token = Data("test-token-with-a-newline\n".utf8)
        var path: String { directory.appendingPathComponent("rpc.sock").path }
        var tokenPath: String { directory.appendingPathComponent("token").path }
        init() throws {
            // Keep the UNIX socket path below sun_path's length limit on both platforms.
            #if canImport(Darwin)
            let temporaryDirectory = URL(fileURLWithPath: "/tmp")
            #else
            // Nix owns its build temporary directory; /tmp may have another owner.
            let temporaryDirectory = FileManager.default.temporaryDirectory
            #endif
            directory = temporaryDirectory.appendingPathComponent("rpc-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            #if canImport(Darwin)
            listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            #else
            listener = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
            #endif
            guard listener >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            #if canImport(Darwin)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            #endif
            let bytes = Array(path.utf8) + [0]
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0, listen(listener, 4) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            chmod(path, 0o600)
            try token.write(to: URL(fileURLWithPath: tokenPath)); chmod(tokenPath, 0o600)
        }
        func serve(_ handler: @escaping (Int32) throws -> Void) {
            DispatchQueue.global().async {
                var entry = pollfd(fd: self.listener, events: Int16(POLLIN), revents: 0)
                guard poll(&entry, 1, 5000) > 0 else { XCTFail("No client"); return }
                let socket = accept(self.listener, nil, nil)
                guard socket >= 0 else { XCTFail("Accept failed: \(errno)"); return }
                defer { close(socket) }
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                #if canImport(Darwin)
                var enabled: Int32 = 1
                setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                #endif
                do { try handler(socket) } catch { XCTFail("Fixture failed: \(error)") }
            }
        }
        func authenticate(_ socket: Int32) throws {
            let nonce = Data((0..<32).map(UInt8.init))
            let hex = nonce.map { String(format: "%02x", $0) }.joined()
            try send(socket, "(:challenge :version 1 :algorithm :hmac-sha-256 :nonce \"\(hex)\")")
            let proof = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: token)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(try receive(socket), .list([.atom(":authenticate"), .atom(":proof"), .string(proof)]))
            try send(socket, "(:authenticated :version 1)")
        }
        func send(_ socket: Int32, _ source: String) throws {
            let bytes = Data(source.utf8), count = UInt32(bytes.count)
            let packet = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + bytes
            // Deliberately fragment the frame across individual writes.
            for byte in packet {
                var value = byte
                #if canImport(Darwin)
                let written = Darwin.send(socket, &value, 1, 0)
                #else
                let written = Glibc.send(socket, &value, 1, Int32(MSG_NOSIGNAL))
                #endif
                guard written == 1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        }
        func receive(_ socket: Int32) throws -> ManagementForm {
            func read(_ count: Int) throws -> Data {
                var data = Data()
                while data.count < count {
                    var byte: UInt8 = 0
                    guard recv(socket, &byte, 1, 0) == 1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    data.append(byte)
                }
                return data
            }
            let count = try read(4).reduce(0) { $0 * 256 + Int($1) }
            guard count > 0 && count <= 1048576 else { throw NSError(domain: "frame", code: 1) }
            return try ManagementForm.parse(read(count))
        }
        func stop() { close(listener); try? FileManager.default.removeItem(at: directory) }
    }

extension ManagementTestServer {
    static func request(_ form: ManagementForm) throws -> [String: Any] {
        guard let source = form.field(":source")?.string,
              let marker = source.range(of: "(json-decode ") else { throw NSError(domain: "source", code: 1) }
        let tail = source[marker.upperBound...]
        var escaped = false, end = tail.startIndex
        guard tail.first == "\"" else { throw NSError(domain: "source", code: 2) }
        for index in tail.indices.dropFirst() {
            let value = tail[index]
            if escaped { escaped = false }
            else if value == "\\" { escaped = true }
            else if value == "\"" { end = tail.index(after: index); break }
        }
        guard let json = try ManagementForm.parse(Data(tail[..<end].utf8)).string,
              let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "source", code: 3)
        }
        return request
    }
    func reply(_ socket: Int32, _ object: [String: Any]) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let printed = ManagementForm.quote(ManagementForm.quote(json))
        try send(socket, "(:evaluation-result :status :ok :values (\(printed)) :values-truncated-p nil :output \"\" :output-truncated-p nil)")
    }
}
