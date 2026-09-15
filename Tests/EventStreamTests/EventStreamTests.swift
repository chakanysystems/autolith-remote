import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import AutolithBridge

final class EventStreamTests: XCTestCase {
    func testKeepAliveAuthenticatesEveryRequestAndHonorsClose() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        for closeExplicitly in [false, true] {
            let socket = try fixture.connect()
            defer { close(socket) }
            for attempt in 0..<3 {
                let body = #"{"operation":"capabilities"}"#
                let token = attempt == 2 && !closeExplicitly ? "wrong" : fixture.token
                let closeHeader = attempt == 2 && closeExplicitly ? "Connection: close\r\n" : ""
                try write(socket, Data("POST /rpc HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\(closeHeader)Content-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
                let response = try header(socket)
                XCTAssertTrue(response.hasPrefix(attempt == 2 && !closeExplicitly ? "HTTP/1.1 401" : "HTTP/1.1 200"))
                let line = try XCTUnwrap(response.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") })
                let length = try XCTUnwrap(Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)))
                _ = try read(socket, length)
                XCTAssertTrue(response.contains(attempt == 2 ? "Connection: close" : "Connection: keep-alive"))
            }
            var byte: UInt8 = 0
            XCTAssertEqual(recv(socket, &byte, 1, 0), 0)
        }
    }
    func testSubscriptionValidation() throws {
        XCTAssertNoThrow(try EventStream.subscription(#"{"operation":"subscribe","id":"s","epoch":"e","after":0}"#))
        for after in ["-1", "true", "1.5", "null", "\"2\""] {
            XCTAssertThrowsError(try EventStream.subscription("{\"operation\":\"subscribe\",\"id\":\"s\",\"after\":\(after)}"))
        }
        XCTAssertThrowsError(try EventStream.subscription(#"{"operation":"tell","id":"s"}"#))
    }

    func testAuthenticatedPollingStream() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let unauthorized = try fixture.connect()
        defer { close(unauthorized) }
        try write(unauthorized, Data(fixture.handshake(token: "incorrect").utf8))
        XCTAssertTrue(try header(unauthorized).hasPrefix("HTTP/1.1 401"))
        let browser = try fixture.connect()
        defer { close(browser) }
        try write(browser, Data(fixture.handshake(origin: true).utf8))
        XCTAssertTrue(try header(browser).hasPrefix("HTTP/1.1 403"))
        let socket = try fixture.connect()
        defer { close(socket) }
        // Include the first masked message in the upgrade packet to test byte handoff.
        try write(socket, Data(fixture.handshake().utf8) + masked(#"{"operation":"subscribe","id":"s"}"#))
        XCTAssertTrue(try header(socket).hasPrefix("HTTP/1.1 101"))
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame(socket).1.utf8)) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame(socket).1.utf8)) as? [String: Any])
        XCTAssertEqual(first["type"] as? String, "snapshot")
        XCTAssertEqual(first["sessionID"] as? String, "s")
        XCTAssertEqual(first["sequence"] as? Int, 1)
        XCTAssertEqual(second["sequence"] as? Int, 2)
        XCTAssertEqual(first["epoch"] as? String, second["epoch"] as? String)
        shutdown(socket, Int32(SHUT_RDWR))
    }

    func testRPCHalfClosedInputStillReceivesResponse() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let socket = try fixture.connect()
        defer { close(socket) }
        let body = #"{"operation":"capabilities"}"#
        try write(socket, Data("POST /rpc HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(fixture.token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        XCTAssertEqual(shutdown(socket, Int32(SHUT_WR)), 0)
        let response = try header(socket)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        let lengthLine = try XCTUnwrap(response.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") })
        let length = try XCTUnwrap(Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)))
        let payload = try read(socket, length)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }

    func testRPCBodyAcrossMultipleTransportReads() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let socket = try fixture.connect()
        defer { close(socket) }
        let body = Data((String(repeating: " ", count: 131_072) + #"{"operation":"capabilities"}"#).utf8)
        try write(socket, Data("POST /rpc HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(fixture.token)\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
        for offset in stride(from: 0, to: body.count, by: 4093) {
            try write(socket, body.subdata(in: offset..<min(offset + 4093, body.count)))
        }
        XCTAssertTrue(try header(socket).hasPrefix("HTTP/1.1 200"))
    }

    func testStreamLimitDoesNotBlockRPC() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        var sockets: [Int32] = []
        defer { sockets.forEach { close($0) } }
        for _ in 0..<4 {
            let socket = try fixture.connect(); sockets.append(socket)
            try write(socket, Data(fixture.handshake().utf8))
            XCTAssertTrue(try header(socket).hasPrefix("HTTP/1.1 101"))
        }
        let extra = try fixture.connect(); sockets.append(extra)
        try write(extra, Data(fixture.handshake().utf8))
        XCTAssertTrue(try header(extra).hasPrefix("HTTP/1.1 503"))
        let rpc = try fixture.connect(); sockets.append(rpc)
        let body = #"{"operation":"capabilities"}"#
        try write(rpc, Data("POST /rpc HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(fixture.token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        XCTAssertTrue(try header(rpc).hasPrefix("HTTP/1.1 200"))
    }

    private struct Failure: Error {}
    private func write(_ socket: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let count = send(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                #else
                let count = send(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                guard count > 0 else { throw Failure() }; offset += count
            }
        }
    }
    private func read(_ socket: Int32, _ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            var buffer = [UInt8](repeating: 0, count: count - result.count)
            let size = recv(socket, &buffer, buffer.count, 0)
            guard size > 0 else { throw Failure() }
            result.append(contentsOf: buffer.prefix(size))
        }
        return result
    }
    private func header(_ socket: Int32) throws -> String {
        var data = Data()
        while !data.suffix(4).elementsEqual([13, 10, 13, 10]) {
            data.append(try read(socket, 1))
            guard data.count < 8192 else { throw Failure() }
        }
        return String(decoding: data, as: UTF8.self)
    }
    private func frame(_ socket: Int32) throws -> (UInt8, String) {
        let head = Array(try read(socket, 2))
        var count = Int(head[1] & 127)
        if count == 126 { count = try read(socket, 2).reduce(0) { $0 * 256 + Int($1) } }
        if count == 127 { count = try read(socket, 8).reduce(0) { $0 * 256 + Int($1) } }
        guard count < 2_097_152 else { throw Failure() }
        return (head[0] & 15, String(decoding: try read(socket, count), as: UTF8.self))
    }
    private func masked(_ text: String) -> Data {
        let bytes = Array(text.utf8), mask: [UInt8] = [1, 2, 3, 4]
        precondition(bytes.count < 126)
        return Data([0x81, 0x80 | UInt8(bytes.count)] + mask + bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    private final class Fixture {
        let directory: URL
        let process = Process()
        let port = UInt16.random(in: 30000...60000)
        let token = UUID().uuidString + UUID().uuidString
        let management: ManagementTestServer
        init() throws {
            management = try ManagementTestServer()
            directory = management.directory
            let tokenFile = directory.appendingPathComponent("bridge-token")
            try token.write(to: tokenFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
            let server = management
            server.serve { socket in
                try server.authenticate(socket)
                while true {
                    let form: ManagementForm
                    do { form = try server.receive(socket) } catch { return }
                    let request = try ManagementTestServer.request(form)
                    if request["operation"] as? String == "identity" { try server.reply(socket, ["id": "gateway"]) }
                    else if request["operation"] as? String == "transcript-source" {
                        try server.reply(socket, ["files": [], "context": [], "status": ["id": "s", "state": "idle"]])
                    } else { try server.reply(socket, ["sessions": [["id": "s", "state": "idle"]]]) }
                }
            }
            // Use this test run's product, including custom SwiftPM scratch paths.
            #if os(macOS)
            let products = Bundle(for: EventStreamTests.self).bundleURL.deletingLastPathComponent()
            #else
            let products = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            #endif
            process.executableURL = products.appendingPathComponent("autolith-bridge")
            var env = ProcessInfo.processInfo.environment
            env["AUTOLITH_BRIDGE_TOKEN_FILE"] = tokenFile.path
            env["AUTOLITH_MANAGEMENT_REPL_UNIX_SOCKET"] = management.path
            env["AUTOLITH_MANAGEMENT_REPL_TOKEN_FILE"] = management.tokenPath
            env["AUTOLITH_BRIDGE_PORT"] = String(port)
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError
            try process.run()
        }
        func handshake(token supplied: String? = nil, origin: Bool = false) -> String {
            "GET /events HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nAuthorization: Bearer \(supplied ?? token)\r\n" + (origin ? "Origin: https://example.com\r\n" : "") + "\r\n"
        }
        func connect() throws -> Int32 {
            let end = Date().addingTimeInterval(5)
            repeat {
                #if canImport(Darwin)
                let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                #else
                let descriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
                #endif
                var address = sockaddr_in()
                #if canImport(Darwin)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                #endif
                address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        #if canImport(Darwin)
                        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        #else
                        Glibc.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        #endif
                    }
                }
                if result == 0 {
                    var timeout = timeval(tv_sec: 5, tv_usec: 0)
                    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    #if canImport(Darwin)
                    var enabled: Int32 = 1
                    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                    #endif
                    return descriptor
                }
                close(descriptor); Thread.sleep(forTimeInterval: 0.02)
            } while Date() < end
            throw Failure()
        }
        func stop() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            management.stop()
        }
    }
}
