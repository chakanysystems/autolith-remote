import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import AutolithBridge

final class ManagementRPCTests: XCTestCase {
    func testReadableStringsAndRejectedReaderSyntax() throws {
        for value in ["quotes \" and \\ backslashes", "line\nλ🙂", "\") #.(delete-file \"x\") ("] {
            XCTAssertEqual(try ManagementForm.parse(Data(ManagementForm.quote(value).utf8)), .string(value))
        }
        for source in ["#.(progn 1)", "(a . b)", "(a) (b)", "\"unfinished", "'a", ")", String(repeating: "(", count: 40) + "nil" + String(repeating: ")", count: 40)] {
            XCTAssertThrowsError(try ManagementForm.parse(Data(source.utf8)), source)
        }
        XCTAssertThrowsError(try ManagementForm.parse(Data([0xff])))
        XCTAssertNil(try ManagementForm.parse(Data("(:x :status :ok :status :bad)".utf8)).field(":status"))
        XCTAssertEqual(try ManagementForm.parse(Data("#A((12) BASE-CHAR . \"SIMPLE-ERROR\")".utf8)), .string("SIMPLE-ERROR"))
        for source in ["#A((1) BASE-CHAR . \"long\")", "#A((1) T . \"x\")", "#A((1 2) CHARACTER . \"ab\")"] {
            XCTAssertThrowsError(try ManagementForm.parse(Data(source.utf8)))
        }
    }

    func testTokenFilePreservesBytesAndRejectsLinksAndPermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = directory.appendingPathComponent("token")
        try Data([1, 2, 10, 255]).write(to: token)
        chmod(token.path, 0o600)
        XCTAssertEqual(try ManagementRPC.readToken(token.path), Data([1, 2, 10, 255]))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: token)
        XCTAssertThrowsError(try ManagementRPC.readToken(link.path))
        chmod(token.path, 0o644)
        XCTAssertThrowsError(try ManagementRPC.readToken(token.path))
        chmod(token.path, 0o600)
        for data in [Data(), Data(repeating: 1, count: 4097)] {
            try data.write(to: token)
            XCTAssertThrowsError(try ManagementRPC.readToken(token.path))
        }
    }

    func testAuthenticatesRawNonceAndReusesConnection() throws {
        let fixture = try ManagementTestServer()
        defer { fixture.stop() }
        let finished = expectation(description: "server")
        fixture.serve { socket in
            defer { finished.fulfill() }
            try fixture.authenticate(socket)
            for _ in 0..<3 {
                let request = try fixture.receive(socket)
                XCTAssertEqual(request.field(":source"), .string("(values 42 :done)"))
                try fixture.send(socket, "(:evaluation-result :status :ok :values (\"42\" \":DONE\") :values-truncated-p nil :output \"\" :output-truncated-p nil)")
            }
        }
        let rpc = ManagementRPC(socketPath: fixture.path, tokenPath: fixture.tokenPath)
        for _ in 0..<3 { XCTAssertEqual(try rpc.evaluate("(values 42 :done)"), ["42", ":DONE"]) }
        wait(for: [finished], timeout: 5)
    }

    func testDisconnectAfterMutationIsNotRetried() throws {
        let fixture = try ManagementTestServer()
        defer { fixture.stop() }
        let finished = expectation(description: "received once")
        fixture.serve { socket in
            defer { finished.fulfill() }
            try fixture.authenticate(socket)
            XCTAssertEqual(try fixture.receive(socket).field(":source"), .string("(incf counter)"))
        }
        let rpc = ManagementRPC(socketPath: fixture.path, tokenPath: fixture.tokenPath, timeout: 1)
        XCTAssertThrowsError(try rpc.evaluate("(incf counter)"))
        wait(for: [finished], timeout: 5)
        var pollEntry = pollfd(fd: fixture.listener, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pollEntry, 1, 100), 0, "No second connection or replay")
    }

    func testAuthenticationFailureDoesNotSendEvaluation() throws {
        let fixture = try ManagementTestServer()
        defer { fixture.stop() }
        let finished = expectation(description: "authentication rejected")
        fixture.serve { socket in
            defer { finished.fulfill() }
            try fixture.send(socket, "(:challenge :version 1 :algorithm :hmac-sha-256 :nonce \"" + String(repeating: "00", count: 32) + "\")")
            XCTAssertEqual(try fixture.receive(socket).list?.first, .atom(":authenticate"))
            try fixture.send(socket, "(:rejected)")
            var byte: UInt8 = 0
            XCTAssertEqual(recv(socket, &byte, 1, 0), 0, "Client closes without sending source")
        }
        let rpc = ManagementRPC(socketPath: fixture.path, tokenPath: fixture.tokenPath, timeout: 1)
        XCTAssertThrowsError(try rpc.evaluate("(incf counter)"))
        wait(for: [finished], timeout: 5)
    }

    func testRejectsFailedAndTruncatedEvaluationsAndOversizedFrames() throws {
        for response in [
            "(:evaluation-result :status :condition :report \"bad request\")",
            "(:evaluation-result :status :timeout :report \"expired\")",
            "(:evaluation-result :status :ok :values (\"partial\") :values-truncated-p t :output-truncated-p nil)",
            "(:evaluation-result :status :ok :values (42) :values-truncated-p nil :output-truncated-p nil)",
            "oversized"
        ] {
            let fixture = try ManagementTestServer()
            defer { fixture.stop() }
            let finished = expectation(description: response)
            fixture.serve { socket in
                defer { finished.fulfill() }
                try fixture.authenticate(socket)
                _ = try fixture.receive(socket)
                if response == "oversized" {
                    let bytes: [UInt8] = [4, 0, 0, 0]
                    #if canImport(Darwin)
                    XCTAssertEqual(Darwin.send(socket, bytes, bytes.count, 0), bytes.count)
                    #else
                    XCTAssertEqual(Glibc.send(socket, bytes, bytes.count, Int32(MSG_NOSIGNAL)), bytes.count)
                    #endif
                } else { try fixture.send(socket, response) }
            }
            let rpc = ManagementRPC(socketPath: fixture.path, tokenPath: fixture.tokenPath, timeout: 1)
            XCTAssertThrowsError(try rpc.evaluate("42"))
            wait(for: [finished], timeout: 5)
        }
    }

    func testAgainstUnmodifiedAutolithWhenConfigured() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["AUTOLITH_TEST_MANAGEMENT_SOCKET"], let token = env["AUTOLITH_TEST_MANAGEMENT_TOKEN"] else {
            throw XCTSkip("Set AUTOLITH_TEST_MANAGEMENT_SOCKET and AUTOLITH_TEST_MANAGEMENT_TOKEN for the real Autolith integration test.")
        }
        let rpc = ManagementRPC(socketPath: path, tokenPath: token)
        XCTAssertEqual(try rpc.evaluate("(values (+ 20 22) :done)"), ["42", ":DONE"])
        XCTAssertThrowsError(try rpc.evaluate("(error \"expected test error\")"))
        XCTAssertEqual(try rpc.evaluate("(values \"λ\\\"hello\" nil)"), ["\"λ\\\"hello\"", "NIL"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rpc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

}
