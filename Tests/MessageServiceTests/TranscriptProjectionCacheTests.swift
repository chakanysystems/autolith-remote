import Foundation
import XCTest
@testable import AutolithBridge

final class TranscriptProjectionCacheTests: XCTestCase {
    func testUnchangedHistoryIsReadOnceAndChangedSourceIsReloaded() throws {
        let cache = TranscriptProjectionCache()
        var revision = "a", reads = 0
        func load() throws -> Data {
            try cache.load(sessionID: "s", context: BackendRequestContext(), source: { revision }) {
                reads += 1
                return Data(#"{"events":[]}"#.utf8)
            }
        }
        for _ in 0..<30 { _ = try load() }
        XCTAssertEqual(reads, 1)
        revision = "b"
        _ = try load()
        XCTAssertEqual(reads, 2)
    }

    func testRacingWriteAndFailedLoadNeverBecomeCachedSnapshots() throws {
        let cache = TranscriptProjectionCache()
        var revision = "a", reads = 0
        _ = try cache.load(sessionID: "s", context: BackendRequestContext(), source: { revision }) {
            reads += 1; revision = "b"
            return Data(#"{"events":[]}"#.utf8)
        }
        for _ in 0..<2 {
            _ = try cache.load(sessionID: "s", context: BackendRequestContext(), source: { revision }) {
                reads += 1
                return Data(#"{"error":"temporarily unavailable"}"#.utf8)
            }
        }
        XCTAssertEqual(reads, 3)
    }

    func testSourceIncludesRewritesReplacementSegmentsAndLiveContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history")
        try Data("old".utf8).write(to: file)
        var source: [String: Any] = ["files": [file.path], "context": []]
        let first = try TranscriptSource.revision(source)
        try Data("new".utf8).write(to: file, options: .atomic)
        let second = try TranscriptSource.revision(source)
        XCTAssertNotEqual(first, second)
        source["context"] = [["text": "local operation"]]
        let third = try TranscriptSource.revision(source)
        XCTAssertNotEqual(second, third)
        source["files"] = []
        XCTAssertNotEqual(third, try TranscriptSource.revision(source))
        source["files"] = [file.path]
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try TranscriptSource.revision(source))
    }

    func testCachedConditionalResponseRejectsChangedReceiptRevision() throws {
        let service = TranscriptService()
        let first = try service.response(sessionID: "s", events: [], revision: nil, source: "files:receipts1")
        let revision = try XCTUnwrap(first["revision"] as? String)
        XCTAssertEqual(service.cachedResponse(sessionID: "s", source: "files:receipts1", revision: revision)?["notModified"] as? Bool, true)
        XCTAssertNil(service.cachedResponse(sessionID: "s", source: "files:receipts2", revision: revision))
        XCTAssertEqual(service.cachedResponse(sessionID: "s", source: "files:receipts1", revision: nil)?["replaceEvents"] as? Bool, true)
    }
}
