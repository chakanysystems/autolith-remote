import XCTest
import Darwin
@testable import AutolithBridge

final class BackendPoolTests: XCTestCase {
    private func fixture(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("backend")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testReusesProcessForConsecutiveRequests() throws {
        let executable = try fixture("read -r handshake\nprintf '%s\\n' '{\"rpcProtocol\":1}'\nwhile read -r request; do printf '{\"pid\":%s}\\n' \"$$\"; done\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let pool = BackendPool(executable: executable.path)
        let request = Data(#"{"operation":"list"}"#.utf8)
        let first = try pool.call(request)
        for _ in 0..<5 { XCTAssertEqual(try pool.call(request), first) }
    }

    func testNeverRetriesMutationAfterUncertainDisconnect() throws {
        let executable = try fixture("read -r handshake\nprintf '%s\\n' '{\"rpcProtocol\":1}'\nread -r request\nprintf '%s\\n' \"$request\" >> \"$0.received\"\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let pool = BackendPool(executable: executable.path)
        XCTAssertThrowsError(try pool.call(Data(#"{"operation":"tell"}"#.utf8)))
        let requests = try String(contentsOfFile: executable.path + ".received").split(separator: "\n")
        XCTAssertEqual(requests.count, 1)
    }

    func testRejectsOldBackendBeforeSendingUserCommand() throws {
        let executable = try fixture("read -r handshake\nprintf '%s\\n' \"$handshake\" > \"$0.received\"\nprintf '%s\\n' '{\"error\":\"Unsupported operation\"}'\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let pool = BackendPool(executable: executable.path)
        XCTAssertThrowsError(try pool.call(Data(#"{"operation":"tell"}"#.utf8)))
        XCTAssertEqual(try String(contentsOfFile: executable.path + ".received").trimmingCharacters(in: .whitespacesAndNewlines), #"{"operation":"rpc-handshake"}"#)
    }

    func testDisposingPoolTerminatesLauncherChildren() throws {
        let executable = try fixture("read -r handshake\nprintf '%s\\n' '{\"rpcProtocol\":1}'\n/bin/sleep 30 &\nchild=$!\nwhile read -r request; do printf '{\"child\":%s}\\n' \"$child\"; done\nwait\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        var pool: BackendPool? = BackendPool(executable: executable.path)
        let result = try JSONSerialization.jsonObject(with: pool!.call(Data(#"{"operation":"list"}"#.utf8))) as! [String: Int32]
        let child = try XCTUnwrap(result["child"])
        XCTAssertEqual(kill(child, 0), 0)
        pool = nil
        let deadline = Date().addingTimeInterval(5)
        while kill(child, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(kill(child, 0), -1)
    }
}
