import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import AutolithBridge

final class EventStreamTests: XCTestCase {
    func testSubscriptionValidation() throws {
        XCTAssertNoThrow(try EventStream.subscription(#"{"operation":"subscribe","id":"s","epoch":"e","after":0}"#))
        for after in ["-1", "true", "1.5", "null", "\"2\""] {
            XCTAssertThrowsError(try EventStream.subscription("{\"operation\":\"subscribe\",\"id\":\"s\",\"after\":\(after)}"))
        }
        XCTAssertThrowsError(try EventStream.subscription(#"{"operation":"tell","id":"s"}"#))
    }

    func testAuthenticatedNativeStreamAndDisconnectCleanup() throws {
        let snapshot = #"{"version":1,"type":"snapshot","sessionID":"s","epoch":"e","sequence":1,"status":{"id":"s"},"activity":[]}"#
        let event = #"{"version":1,"type":"event","sessionID":"s","epoch":"e","sequence":2,"kind":"job","payload":{"state":"running"}}"#
        let fixture = try Fixture(script: "read -r request\nprintf '%s' \"$request\" > \"$TEST_REQUEST\"\necho $$ > \"$TEST_PID\"\nprintf '%s\\n' 'boot diagnostic' '\(snapshot)' '\(event)'\nexec \(fixtureSleepPath()) 30\n")
        defer { fixture.stop() }
        let unauthorized = try fixture.connect()
        defer { close(unauthorized) }
        try write(unauthorized, Data(fixture.handshake(token: "incorrect").utf8))
        XCTAssertTrue(try header(unauthorized).hasPrefix("HTTP/1.1 401"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pidFile.path))
        let browser = try fixture.connect()
        defer { close(browser) }
        try write(browser, Data(fixture.handshake(origin: true).utf8))
        XCTAssertTrue(try header(browser).hasPrefix("HTTP/1.1 403"))
        let socket = try fixture.connect()
        defer { close(socket) }
        // Include a masked first message in the upgrade packet to exercise byte handoff.
        let request = #"{"operation":"subscribe","id":"s","epoch":"old","after":3}"#
        try write(socket, Data(fixture.handshake().utf8) + masked(request))
        XCTAssertTrue(try header(socket).hasPrefix("HTTP/1.1 101"))
        XCTAssertEqual(try frame(socket).1, snapshot)
        XCTAssertEqual(try frame(socket).1, event)
        let forwarded = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.requestFile)) as? NSDictionary
        XCTAssertEqual(forwarded, try JSONSerialization.jsonObject(with: Data(request.utf8)) as? NSDictionary)
        let pid = try XCTUnwrap(Int32(String(contentsOf: fixture.pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0, "Events must arrive while backend is still running")
        shutdown(socket, Int32(SHUT_RDWR))
        try assertProcessTerminates(pid, timeout: 5)
    }

    func testLegacyBackendErrorIsDelivered() throws {
        let fixture = try Fixture(script: "read -r request\nprintf '%s\\n' 'boot diagnostic' '{\"error\":\"Unsupported operation\"}'\n")
        defer { fixture.stop() }
        let socket = try fixture.connect()
        defer { close(socket) }
        try write(socket, Data(fixture.handshake().utf8))
        XCTAssertTrue(try header(socket).hasPrefix("HTTP/1.1 101"))
        try write(socket, masked(#"{"operation":"subscribe","id":"s"}"#))
        let response = try frame(socket)
        XCTAssertEqual(response.0, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.1.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "error")
        XCTAssertEqual(object["error"] as? String, "Unsupported operation")
        XCTAssertEqual(try frame(socket).0, 8)
    }

    func testMalformedOrCrossSessionNativeEventsAreRejected() throws {
        let snapshot = #"{"version":1,"type":"snapshot","sessionID":"s","epoch":"e","sequence":0,"status":{"id":"s"},"activity":[]}"#
        for event in [
            #"{"version":1,"type":"event","sessionID":"other","epoch":"e","sequence":1,"kind":"activity","payload":{}}"#,
            #"{"version":1,"type":"event","sessionID":"s","epoch":"e","sequence":2,"kind":"activity","payload":{}}"#,
            #"{"version":1,"type":"event","sessionID":"s","epoch":"e","sequence":true,"kind":"activity","payload":{}}"#
        ] {
            let fixture = try Fixture(script: "read -r request\nprintf '%s\\n' '\(snapshot)' '\(event)'\n")
            defer { fixture.stop() }
            let socket = try fixture.connect()
            defer { close(socket) }
            try write(socket, Data(fixture.handshake().utf8) + masked(#"{"operation":"subscribe","id":"s"}"#))
            XCTAssertTrue(try header(socket).hasPrefix("HTTP/1.1 101"))
            XCTAssertEqual(try frame(socket).1, snapshot)
            let response = try JSONSerialization.jsonObject(with: Data(frame(socket).1.utf8)) as? [String: Any]
            XCTAssertEqual(response?["type"] as? String, "error")
            XCTAssertEqual(try frame(socket).0, 8)
        }
    }

    func testDisconnectKillsDescendantAfterLauncherExitsWithOpenPipe() throws {
        let snapshot = #"{"version":1,"type":"snapshot","sessionID":"s","epoch":"e","sequence":0,"status":{"id":"s"},"activity":[]}"#
        let fixture = try Fixture(script: "read -r request\n\(fixtureSleepPath()) 30 &\necho $! > \"$TEST_PID\"\nprintf '%s\\n' '\(snapshot)'\nexit 0\n")
        defer { fixture.stop() }
        let socket = try fixture.connect()
        defer { close(socket) }
        try write(socket, Data(fixture.handshake().utf8) + masked(#"{"operation":"subscribe","id":"s"}"#))
        XCTAssertTrue(try header(socket).hasPrefix("HTTP/1.1 101"))
        XCTAssertEqual(try frame(socket).1, snapshot)
        let pid = try XCTUnwrap(Int32(String(contentsOf: fixture.pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        Thread.sleep(forTimeInterval: 0.1)
        shutdown(socket, Int32(SHUT_RDWR))
        try assertProcessTerminates(pid, timeout: 3)
    }

    func testDisconnectCancelsSubscriptionWithBackendThatNeverReadsOrWrites() throws {
        let fixture = try Fixture(script: "echo $$ > \"$TEST_PID\"\nexec \(fixtureSleepPath()) 30\n")
        defer { fixture.stop() }
        let socket = try fixture.connect()
        defer { close(socket) }
        try write(socket, Data(fixture.handshake().utf8) + masked(#"{"operation":"subscribe","id":"s"}"#))
        XCTAssertTrue(try header(socket).hasPrefix("HTTP/1.1 101"))
        let startup = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: fixture.pidFile.path) && Date() < startup { Thread.sleep(forTimeInterval: 0.01) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: fixture.pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        shutdown(socket, Int32(SHUT_RDWR))
        try assertProcessTerminates(pid, timeout: 3)
    }

    func testUnterminatedBackendEnvelopeIsRejected() throws {
        let snapshot = #"{"version":1,"type":"snapshot","sessionID":"s","epoch":"e","sequence":0,"status":{"id":"s"},"activity":[]}"#
        let fixture = try Fixture(script: "read -r request\nprintf '%s' '\(snapshot)'\n")
        defer { fixture.stop() }
        let socket = try fixture.connect()
        defer { close(socket) }
        try write(socket, Data(fixture.handshake().utf8) + masked(#"{"operation":"subscribe","id":"s"}"#))
        XCTAssertTrue(try header(socket).hasPrefix("HTTP/1.1 101"))
        let response = try JSONSerialization.jsonObject(with: Data(frame(socket).1.utf8)) as? [String: Any]
        XCTAssertEqual(response?["type"] as? String, "error")
        XCTAssertEqual(try frame(socket).0, 8)
    }

    func testRPCHalfClosedInputStillReceivesResponse() throws {
        let fixture = try Fixture(script: "exit 0\n")
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
        let fixture = try Fixture(script: "exit 0\n")
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
        let fixture = try Fixture(script: "exit 0\n")
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
        var pidFile: URL { directory.appendingPathComponent("pid") }
        var requestFile: URL { directory.appendingPathComponent("request") }
        init(script: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tokenFile = directory.appendingPathComponent("token"), native = directory.appendingPathComponent("native")
            try token.write(to: tokenFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
            try ("#!\(try fixtureShellPath())\n" + script).write(to: native, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: native.path)
            // Use this test run's product, including custom SwiftPM scratch paths.
            #if os(macOS)
            let products = Bundle(for: EventStreamTests.self).bundleURL.deletingLastPathComponent()
            #else
            let products = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            #endif
            process.executableURL = products.appendingPathComponent("autolith-bridge")
            var env = ProcessInfo.processInfo.environment
            env["AUTOLITH_BRIDGE_TOKEN_FILE"] = tokenFile.path
            env["AUTOLITH_EXECUTABLE"] = native.path
            env["AUTOLITH_BRIDGE_PORT"] = String(port)
            env["TEST_PID"] = pidFile.path; env["TEST_REQUEST"] = requestFile.path
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
            if let contents = try? String(contentsOf: pidFile), let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
