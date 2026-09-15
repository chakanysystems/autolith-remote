import XCTest
@testable import BridgeCore

final class PrivateFileTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func credential(in directory: URL, bytes: Data = Data("fixture-token".utf8)) throws -> URL {
        let url = directory.appendingPathComponent("credential")
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func testReadsPrivateOwnedFile() throws {
        try withDirectory { directory in
            let url = try credential(in: directory)
            XCTAssertEqual(try PrivateFile.readSecret(at: url), Data("fixture-token".utf8))
        }
    }

    func testRejectsSymlinkAndPublicFile() throws {
        try withDirectory { directory in
            let url = try credential(in: directory)
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            XCTAssertThrowsError(try PrivateFile.readSecret(at: alias))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            XCTAssertThrowsError(try PrivateFile.readSecret(at: url))
        }
    }

    func testRejectsPublicParentAndWritableAncestor() throws {
        try withDirectory { directory in
            let parent = directory.appendingPathComponent("shared")
            let child = parent.appendingPathComponent("private")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = try credential(in: child)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)
            XCTAssertThrowsError(try PrivateFile.readSecret(at: url))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: parent.path)
            XCTAssertThrowsError(try PrivateFile.readSecret(at: url))
        }
    }

    func testBoundsReadAndRejectsDirectories() throws {
        try withDirectory { directory in
            let url = try credential(in: directory, bytes: Data(repeating: 65, count: 33))
            XCTAssertThrowsError(try PrivateFile.readSecret(at: url, maximumBytes: 32))
            let nested = directory.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            XCTAssertThrowsError(try PrivateFile.readSecret(at: nested))
        }
    }
}
