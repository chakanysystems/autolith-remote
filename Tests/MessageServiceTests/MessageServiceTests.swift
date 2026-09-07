import XCTest
@testable import AutolithBridge
@testable import ClientCore

final class MessageServiceTests: XCTestCase {
    func testUncertainReceiptDoesNotHideLaterExecutedAnswer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try MessageService(file: directory.appendingPathComponent("outbox.json")) { _ in [:] }
        let now = Date().timeIntervalSince1970
        let id = UUID().uuidString
        _ = try service.outbox.enqueue(id: id, sessionID: "s", workspace: "/fixture", text: "old", now: now - 100)
        _ = try service.outbox.claim(now: now - 80)
        try service.outbox.finish(id, delivered: false)
        let transcript: [[String: Any]] = [
            ["id": "1", "role": "user", "tool": "", "text": "new", "timestamp": now - 20],
            ["id": "2", "role": "assistant", "tool": "", "text": "answer", "timestamp": now - 10]
        ]
        let decorated = service.decorateTranscript(["events": transcript], sessionID: "s")
        let events = try JSONDecoder().decode([Event].self, from: JSONSerialization.data(withJSONObject: decorated["events"]!))
        XCTAssertEqual(SiriContent.latestAnswer(in: events), "answer")
        XCTAssertTrue(events.contains { $0.deliveryState == "uncertain" })
        let newer = Event(id: "outbox-new", role: "user", tool: "", text: "new uncertain", timestamp: now, deliveryState: "uncertain")
        XCTAssertNil(SiriContent.latestAnswer(in: events + [newer]))
    }

    func testExpiredReceiptIsOmittedAndBatchReturnsOnlyRequestedMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let service = try MessageService(file: directory.appendingPathComponent("outbox.json")) { request in
            calls += 1
            XCTAssertEqual(request["after"] as? Int, 19)
            return ["events": [["id": "20", "role": "assistant", "text": "wanted"],
                               ["id": "2", "role": "assistant", "text": "unrequested"],
                               ["id": "30", "role": "tool", "text": "private"]]]
        }
        let now = Date().timeIntervalSince1970
        let id = UUID().uuidString
        _ = try service.outbox.enqueue(id: id, sessionID: "s", workspace: "/fixture", text: "expired", now: now - 40 * 86400)
        _ = try service.outbox.claim(now: now - 40 * 86400 + 20)
        try service.outbox.finish(id, delivered: true, now: now - 40 * 86400 + 21)
        _ = try service.outbox.claim(now: now)
        let eventID = "outbox-" + id
        let missing = try XCTUnwrap(service.handle(["operation": "message-get", "id": "s", "eventID": eventID]))
        XCTAssertEqual((missing["events"] as? [[String: Any]])?.count, 0)
        let receiptOnly = try XCTUnwrap(service.handle(["operation": "message-events", "id": "s", "eventIDs": [eventID]]))
        XCTAssertEqual((receiptOnly["events"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(calls, 0)
        let batch = try XCTUnwrap(service.handle(["operation": "message-events", "id": "s", "eventIDs": [eventID, "20", "30"]]))
        XCTAssertEqual((batch["events"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["20"])
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try service.handle(["operation": "message-events", "id": "s", "eventIDs": Array(repeating: "1", count: 101)]))
    }
}
