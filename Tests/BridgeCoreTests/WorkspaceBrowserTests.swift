import XCTest
@testable import BridgeCore

final class WorkspaceBrowserTests: XCTestCase {
    func testListsFoldersAndTraversesParent() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for name in ["Project 10", "Project 2", ".hidden"] {
            try manager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("file.txt"))
        let listing = try WorkspaceBrowser.listing(path: root.path)
        let folders = try XCTUnwrap(listing["directories"] as? [String])
        XCTAssertEqual(folders.map { URL(fileURLWithPath: $0).lastPathComponent }, ["Project 2", "Project 10"])
        let child = try WorkspaceBrowser.listing(path: folders[0])
        XCTAssertEqual(child["directories"] as? [String], [])
        let parent = try WorkspaceBrowser.listing(path: folders[0] + "/..")
        XCTAssertEqual(parent["directory"] as? String, listing["directory"] as? String)
        XCTAssertThrowsError(try WorkspaceBrowser.listing(path: root.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try WorkspaceBrowser.listing(path: root.appendingPathComponent("file.txt").path))
        XCTAssertThrowsError(try WorkspaceBrowser.listing(path: "relative/path"))
    }
}
