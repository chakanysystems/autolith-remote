import XCTest
@testable import AutolithBridge
@testable import ClientCore

final class TranscriptServiceTests: XCTestCase {
    func testContentRevisionCoversRewriteDeleteReorderAndReadState() throws {
        let service = TranscriptService()
        let initial: [[String: Any]] = [
            ["id": "1", "role": "assistant", "tool": "", "text": "old", "isRead": false],
            ["id": "2", "role": "assistant", "tool": "", "text": "deleted"],
            ["id": "3", "role": "assistant", "tool": "", "text": "last"]
        ]
        let first = try service.response(sessionID: "s", events: initial, revision: nil)
        let revision = try XCTUnwrap(first["revision"] as? String)
        XCTAssertEqual(first["replaceEvents"] as? Bool, true)
        let same = try service.response(sessionID: "s", events: initial, revision: revision)
        XCTAssertEqual(same["notModified"] as? Bool, true)
        XCTAssertNil(same["events"])
        let rewritten: [[String: Any]] = [initial[2], ["id": "1", "role": "assistant", "tool": "", "text": "new", "isRead": true]]
        let delta = try service.response(sessionID: "s", events: rewritten, revision: revision)
        XCTAssertEqual(delta["baseRevision"] as? String, revision)
        XCTAssertEqual(delta["eventOrder"] as? [String], ["3", "1"])
        XCTAssertEqual((delta["events"] as? [[String: Any]])?.count, 1)
        var cache = CachedTranscript(revision: revision, events: try JSONDecoder().decode([Event].self, from: JSONSerialization.data(withJSONObject: initial)), accessed: Date())
        try cache.reconcile(revision: XCTUnwrap(delta["revision"] as? String), base: revision, order: delta["eventOrder"] as? [String], changes: JSONDecoder().decode([Event].self, from: JSONSerialization.data(withJSONObject: delta["events"]!)), unchanged: false)
        XCTAssertEqual(cache.events.map(\.text), ["last", "new"])
        let unknown = try service.response(sessionID: "s", events: [], revision: "unknown")
        XCTAssertEqual(unknown["replaceEvents"] as? Bool, true)
        XCTAssertTrue((unknown["events"] as? [[String: Any]])?.isEmpty == true)
    }

    func testBatchReadValidatesOnceAndIgnoresDeletedAndToolEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let service = try MessageService(file: directory.appendingPathComponent("outbox.json")) { _ in
            calls += 1
            return ["events": [["id": "1", "role": "assistant"], ["id": "2", "role": "user"], ["id": "3", "role": "tool"]]]
        }
        let response = try XCTUnwrap(service.handle(["operation": "messages-read", "id": "s", "eventIDs": ["1", "2", "3", "deleted"]]))
        XCTAssertEqual(response["readIDs"] as? [String], ["1", "2"])
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try service.handle(["operation": "messages-read", "id": "s", "eventIDs": Array(repeating: "1", count: 101)]))
        XCTAssertEqual(calls, 1)
    }
}
