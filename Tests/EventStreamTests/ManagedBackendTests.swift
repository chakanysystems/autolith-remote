import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import AutolithBridge

final class ManagedBackendTests: XCTestCase {
    private enum FixtureError: Error { case notReady, missingPID }

    private func directory() throws -> URL {
        #if canImport(Darwin)
        let root = URL(fileURLWithPath: "/tmp")
        #else
        let root = FileManager.default.temporaryDirectory
        #endif
        let result = root.appendingPathComponent("mb-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    private func fixture(in directory: URL) throws -> [String: String] {
        let executable = directory.appendingPathComponent("backend")
        // Record only these safe fields. Never copy the complete environment or token contents.
        let script = """
        #!\(try fixtureShellPath())
        trap '' TERM
        printf '%s\\n' "$$" > "$FIXTURE_DIRECTORY/pid"
        {
          printf 'arg=%s\\n' "$@"
          printf 'style=%s\\n' "$AUTOLITH_SESSION_STYLE"
          printf 'enabled=%s\\n' "$AUTOLITH_MANAGEMENT_REPL"
          printf 'transport=%s\\n' "$AUTOLITH_MANAGEMENT_REPL_TRANSPORT"
          printf 'socket=%s\\n' "$AUTOLITH_MANAGEMENT_REPL_UNIX_SOCKET"
          printf 'tokenPath=%s\\n' "$AUTOLITH_MANAGEMENT_REPL_TOKEN_FILE"
        } > "$FIXTURE_DIRECTORY/launch"
        while :; do \(try fixtureSleepPath()) 1; done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return ["AUTOLITH_EXECUTABLE": executable.path, "FIXTURE_DIRECTORY": directory.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""]
    }

    private func startedPID(in directory: URL) throws -> Int32 {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("launch").path),
               let text = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                XCTAssertEqual(kill(pid, 0), 0)
                return pid
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        throw FixtureError.missingPID
    }

    private func assertStopped(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }

    func testOnlyOneBridgeCanOwnGatewayDirectory() throws {
        let directory = try directory()
        let first = try ManagedBackend(environment: [:], tokenDirectory: directory)
        XCTAssertThrowsError(try ManagedBackend(environment: [:], tokenDirectory: directory))
        first.stop()
        let next = try ManagedBackend(environment: [:], tokenDirectory: directory)
        next.stop()
    }

    func testCreatesPrivateTokenAndReusesItAfterRestart() throws {
        let directory = try directory()
        let first = try ManagedBackend(environment: [:], tokenDirectory: directory)
        XCTAssertTrue(first.ownsGateway)
        let tokenURL = URL(fileURLWithPath: first.tokenPath)
        let original = try Data(contentsOf: tokenURL)
        XCTAssertGreaterThanOrEqual(original.count, 32)
        let attributes = try FileManager.default.attributesOfItem(atPath: first.tokenPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: tokenURL.deletingLastPathComponent().path)
        XCTAssertEqual((parentAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        first.stop()
        let second = try ManagedBackend(environment: [:], tokenDirectory: directory)
        defer { second.stop() }
        XCTAssertEqual(second.tokenPath, first.tokenPath)
        XCTAssertEqual(second.socketPath, first.socketPath)
        // Boolean comparison prevents XCTest from printing secret bytes on failure.
        XCTAssertTrue(try Data(contentsOf: tokenURL) == original)
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: second.tokenPath)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, secondAttributes[.systemFileNumber] as? NSNumber)
    }

    func testRejectsHalfConfiguredExternalEndpoint() throws {
        let directory = try directory()
        for key in ["AUTOLITH_MANAGEMENT_REPL_UNIX_SOCKET", "AUTOLITH_MANAGEMENT_REPL_TOKEN_FILE"] {
            XCTAssertThrowsError(try ManagedBackend(environment: [key: "/tmp/unused"], tokenDirectory: directory))
        }
    }

    func testStopDoesNotCloseExternalManagementServer() throws {
        let server = try ManagementTestServer()
        defer { server.stop() }
        let complete = expectation(description: "external endpoint accepts request after stop")
        server.serve { socket in
            defer { complete.fulfill() }
            try server.authenticate(socket)
            for _ in 0..<2 {
                XCTAssertEqual(try ManagementTestServer.request(server.receive(socket))["operation"] as? String, "identity")
                try server.reply(socket, ["id": "external"])
            }
        }
        let managed = try ManagedBackend(environment: ["AUTOLITH_MANAGEMENT_REPL_UNIX_SOCKET": server.path,
                                                       "AUTOLITH_MANAGEMENT_REPL_TOKEN_FILE": server.tokenPath],
                                         tokenDirectory: server.directory)
        defer { managed.stop() }
        XCTAssertFalse(managed.ownsGateway)
        try managed.start(timeout: 3)
        managed.stop()
        try managed.backend.checkConnection()
        wait(for: [complete], timeout: 5)
    }

    func testLaunchesGatewayAndStopsOwnedChild() throws {
        let directory = try directory()
        let managed = try ManagedBackend(environment: fixture(in: directory), tokenDirectory: directory)
        defer { managed.stop() }
        var pid: Int32 = 0
        try managed.start(timeout: 5) { _, _ in pid = try self.startedPID(in: directory) }
        let launch = try String(contentsOf: directory.appendingPathComponent("launch"), encoding: .utf8)
        XCTAssertEqual(launch.components(separatedBy: .newlines).filter { !$0.isEmpty }, [
            "arg=--permissions", "arg=ask", "style=direct", "enabled=on", "transport=unix",
            "socket=" + managed.socketPath, "tokenPath=" + managed.tokenPath
        ])
        managed.stop()
        XCTAssertEqual(kill(pid, 0), -1, "stop must finish cleanup before the bridge exits")
        XCTAssertEqual(errno, ESRCH)
    }

    func testReadinessFailureStopsOwnedChildAtDeadline() throws {
        let directory = try directory()
        let managed = try ManagedBackend(environment: fixture(in: directory), tokenDirectory: directory)
        defer { managed.stop() }
        var pid: Int32 = 0
        var attempts = 0
        XCTAssertThrowsError(try managed.start(timeout: 0.5) { _, _ in
            pid = try self.startedPID(in: directory)
            attempts += 1
            throw FixtureError.notReady
        })
        XCTAssertGreaterThan(attempts, 0)
        guard pid > 0 else { return XCTFail("Fixture did not start") }
        assertStopped(pid)
    }

    func testExpiredReadinessContextStopsOwnedChild() throws {
        let directory = try directory()
        let managed = try ManagedBackend(environment: fixture(in: directory), tokenDirectory: directory)
        defer { managed.stop() }
        var pid: Int32 = 0
        XCTAssertThrowsError(try managed.start(timeout: 0.5) { _, context in
            pid = try self.startedPID(in: directory)
            Thread.sleep(forTimeInterval: max(0, context.remaining) + 0.02)
            try context.check()
        })
        guard pid > 0 else { return XCTFail("Fixture did not start") }
        assertStopped(pid)
    }
}
