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

    func testStopAllowsTermHandlerBeforeForcedCleanup() throws {
        let executable = try fixture("trap 'printf stopped > \"$0.stopped\"; exit 0' TERM\nread -r handshake\nprintf '%s\\n' '{\"rpcProtocol\":1}'\nread -r request\nprintf '%s\\n' '{\"ok\":true}'\nwhile :; do :; done\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        var pool: BackendPool? = BackendPool(executable: executable.path)
        _ = try pool!.call(Data(#"{"operation":"list"}"#.utf8))
        pool = nil
        let limit = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: executable.path + ".stopped") && Date() < limit {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path + ".stopped"))
    }
    func testHandshakeAndRequestShareDeadline() throws {
        let executable = try fixture("read -r handshake\nsleep 0.15\nprintf '%s\\n' '{\"rpcProtocol\":1}'\nread -r request\nprintf '%s\\n' \"$request\" > \"$0.received\"\nsleep 0.4\nprintf '%s\\n' '{\"ok\":true}'\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let pool = BackendPool(executable: executable.path)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try pool.call(Data(#"{"operation":"tell"}"#.utf8), deadline: .now() + 0.3))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path + ".received"))
    }

    func testCancelledHandshakeNeverDispatchesMutation() throws {
        let executable = try fixture("read -r handshake\nprintf 'started' > \"$0.started\"\nsleep 1\nprintf '%s\\n' '{\"rpcProtocol\":1}'\nread -r request\nprintf '%s\\n' \"$request\" > \"$0.received\"\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let pool = BackendPool(executable: executable.path)
        let context = BackendRequestContext(deadline: .now() + 5)
        let finished = expectation(description: "cancelled")
        DispatchQueue.global().async {
            XCTAssertThrowsError(try pool.call(Data(#"{"operation":"tell"}"#.utf8), context: context))
            finished.fulfill()
        }
        let limit = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: executable.path + ".started") && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path + ".started"))
        context.cancel()
        wait(for: [finished], timeout: 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path + ".received"))
    }

    func testExpiredPoolWaiterIsNeverDispatched() throws {
        let executable = try fixture("read -r handshake\nprintf '%s\\n' '{\"rpcProtocol\":1}'\nread -r request\nprintf '%s\\n' \"$request\" >> \"$0.received\"\nsleep 2\nprintf '%s\\n' '{\"ok\":true}'\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let pool = BackendPool(executable: executable.path)
        let contexts = (0..<4).map { _ in BackendRequestContext(deadline: .now() + 5) }
        let finished = expectation(description: "workers stopped"); finished.expectedFulfillmentCount = 4
        for context in contexts {
            DispatchQueue.global().async {
                _ = try? pool.call(Data(#"{"operation":"list"}"#.utf8), context: context)
                finished.fulfill()
            }
        }
        let limit = Date().addingTimeInterval(2)
        var observed = 0
        repeat {
            observed = (try? String(contentsOfFile: executable.path + ".received").split(separator: "\n").count) ?? 0
            if observed < 4 { Thread.sleep(forTimeInterval: 0.01) }
        } while observed < 4 && Date() < limit
        XCTAssertEqual(observed, 4)
        XCTAssertThrowsError(try pool.call(Data(#"{"operation":"tell"}"#.utf8), deadline: .now() + 0.1))
        let queued = BackendRequestContext(deadline: .now() + 5)
        let cancelled = expectation(description: "queued cancellation")
        DispatchQueue.global().async {
            XCTAssertThrowsError(try pool.call(Data(#"{"operation":"tell"}"#.utf8), context: queued))
            cancelled.fulfill()
        }
        queued.cancel()
        wait(for: [cancelled], timeout: 0.5)
        contexts.forEach { $0.cancel() }
        wait(for: [finished], timeout: 1)
        XCTAssertFalse(try String(contentsOfFile: executable.path + ".received").contains("tell"))
    }

    func testRejectsExtraReplyAndPartialSurplus() throws {
        for extra in ["{\"stale\":true}\\n", "partial"] {
            let executable = try fixture("read -r handshake\nprintf '%s\\n' '{\"rpcProtocol\":1}'\nread -r request\nprintf '{\"ok\":true}\\n" + extra + "'\nsleep 2\n")
            defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
            XCTAssertThrowsError(try BackendPool(executable: executable.path).call(Data(#"{"operation":"list"}"#.utf8)))
        }
    }

    func testRejectsLateIdleOutputBeforeNextDispatch() throws {
        let executable = try fixture("read -r handshake\nprintf '%s\\n' '{\"rpcProtocol\":1}'\nread -r request\nprintf '%s\\n' '{\"ok\":true}'\nsleep 0.1\nprintf '%s\\n' '{\"stale\":true}'\nprintf ready > \"$0.ready\"\nread -r request\nprintf '%s\\n' \"$request\" > \"$0.received\"\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let pool = BackendPool(executable: executable.path)
        _ = try pool.call(Data(#"{"operation":"list"}"#.utf8))
        let limit = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: executable.path + ".ready") && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path + ".ready"))
        XCTAssertThrowsError(try pool.call(Data(#"{"operation":"tell"}"#.utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path + ".received"))
    }

    func testExitedLauncherDescendantsAreKilledOnTimeout() throws {
        let executable = try fixture("read -r handshake\nprintf '%s\\n' '{\"rpcProtocol\":1}'\nread -r request\n/bin/sleep 30 &\nprintf '%s' \"$!\" > \"$0.child\"\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let pool = BackendPool(executable: executable.path)
        XCTAssertThrowsError(try pool.call(Data(#"{"operation":"list"}"#.utf8), deadline: .now() + 0.3))
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: executable.path + ".child")))
        let limit = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(kill(pid, 0), -1)
    }
}
