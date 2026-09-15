import XCTest
@testable import BridgeCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class BridgeTokenTests: XCTestCase {
    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    func testCreatesPrivateRandomTokenAndReusesIt() throws {
        try withHome { home in
            let environment = ["HOME": home.path]
            let first = try BridgeToken(environment: environment)
            XCTAssertEqual(first.file.path, home.path + "/.local/state/autolith-bridge/token")
            XCTAssertEqual(first.value.count, 64)
            XCTAssertTrue(first.value.allSatisfy { "0123456789abcdef".contains($0) })
            XCTAssertEqual(try PrivateFile.readSecret(at: first.file), Data(first.value.utf8))
            XCTAssertEqual(try BridgeToken(environment: environment).value, first.value)
            let second = try BridgeToken(environment: ["XDG_STATE_HOME": home.appendingPathComponent("other").path])
            XCTAssertNotEqual(second.value, first.value)
            XCTAssertEqual(second.file.path, home.path + "/other/autolith-bridge/token")
        }
    }

    func testEmptyXDGUsesHomeAndInvalidPathsFail() throws {
        try withHome { home in
            let token = try BridgeToken(environment: ["HOME": home.path, "XDG_STATE_HOME": ""])
            XCTAssertEqual(token.file.path, home.path + "/.local/state/autolith-bridge/token")
        }
        XCTAssertThrowsError(try BridgeToken(environment: [:]))
        XCTAssertThrowsError(try BridgeToken(environment: ["XDG_STATE_HOME": "relative"]))
        XCTAssertThrowsError(try BridgeToken(environment: ["HOME": "relative"]))
    }

    func testExplicitPathIsReadOnlyAndValidatesText() throws {
        try withHome { home in
            let file = home.appendingPathComponent("custom")
            let environment = ["AUTOLITH_BRIDGE_TOKEN_FILE": file.path]
            XCTAssertThrowsError(try BridgeToken(environment: environment))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            for bytes in [Data(), Data("short".utf8), Data(repeating: 255, count: 64)] {
                try bytes.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                XCTAssertThrowsError(try BridgeToken(environment: environment))
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
            let bytes = Data((String(repeating: "a", count: 32) + "\n").utf8)
            try bytes.write(to: file)
            XCTAssertEqual(try BridgeToken(environment: environment).value, String(repeating: "a", count: 32))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testDefaultRejectsUnsafeOrInvalidExistingTokenWithoutReplacement() throws {
        try withHome { home in
            let environment = ["XDG_STATE_HOME": home.path]
            let token = try BridgeToken(environment: environment)
            let bytes = try Data(contentsOf: token.file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: token.file.path)
            XCTAssertThrowsError(try BridgeToken(environment: environment))
            XCTAssertEqual(try Data(contentsOf: token.file), bytes)
            try FileManager.default.removeItem(at: token.file)
            let target = home.appendingPathComponent("target")
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(at: token.file, withDestinationURL: target)
            XCTAssertThrowsError(try BridgeToken(environment: environment))
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            try FileManager.default.removeItem(at: token.file)
            XCTAssertEqual(mkfifo(token.file.path, 0o600), 0)
            XCTAssertThrowsError(try BridgeToken(environment: environment))
            try FileManager.default.removeItem(at: token.file)
            try Data().write(to: token.file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.file.path)
            XCTAssertThrowsError(try BridgeToken(environment: environment))
            XCTAssertEqual(try Data(contentsOf: token.file).count, 0)
        }
    }

    func testRejectsUnsafeDirectoryBeforeCreatingToken() throws {
        try withHome { home in
            let directory = home.appendingPathComponent("autolith-bridge")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            XCTAssertThrowsError(try BridgeToken(environment: ["XDG_STATE_HOME": home.path]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("token").path))
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: home)
            XCTAssertThrowsError(try BridgeToken(environment: ["XDG_STATE_HOME": home.path]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("token").path))
        }
    }
}
