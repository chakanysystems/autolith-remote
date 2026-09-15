import XCTest
@testable import ClientCore

final class SessionStreamTests: XCTestCase {
    func testSnapshotRevisionSuppressesUnchangedHistoryButResyncsAfterReconnect() throws {
        var stream = SessionStream(sessionID: "s")
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: message("snapshot")) as? [String: Any])
        body["transcriptRevision"] = "a"
        _ = try stream.receive(JSONSerialization.data(withJSONObject: body))
        XCTAssertTrue(stream.transcriptChanged)
        for sequence in 2...30 {
            body["sequence"] = sequence
            _ = try stream.receive(JSONSerialization.data(withJSONObject: body))
            XCTAssertFalse(stream.transcriptChanged)
        }
        body["transcriptRevision"] = "b"
        _ = try stream.receive(JSONSerialization.data(withJSONObject: body))
        XCTAssertTrue(stream.transcriptChanged)
        body["epoch"] = "reconnected"
        _ = try stream.receive(JSONSerialization.data(withJSONObject: body))
        XCTAssertTrue(stream.transcriptChanged)
        body.removeValue(forKey: "transcriptRevision")
        _ = try stream.receive(JSONSerialization.data(withJSONObject: body))
        XCTAssertTrue(stream.transcriptChanged)
    }
    private func message(_ type: String = "event", sequence: Int = 1, epoch: String = "a", id: String = "s", eventID: String = "e", text: String = "hello") throws -> Data {
        var body: [String: Any] = ["version": 1, "type": type, "sessionID": id, "epoch": epoch, "sequence": sequence]
        let event: [String: Any] = ["id": eventID, "role": "tool-progress", "tool": "rlm.infer", "text": text]
        if type == "snapshot" {
            body["status"] = ["id": id, "title": "Test", "state": "working", "workspace": "/", "model": "test", "permissions": "ask", "queued": 0, "jobs": 2]
            body["activity"] = [event]
        } else { body["kind"] = "tool-progress"; body["payload"] = ["event": event] }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func testSnapshotReplacementReplayAndCumulativeText() throws {
        var stream = SessionStream(sessionID: "s")
        XCTAssertTrue(try stream.receive(message("snapshot", sequence: 4)))
        XCTAssertEqual(stream.status?.jobs, 2)
        XCTAssertTrue(try stream.receive(message(sequence: 5, text: "hello world")))
        XCTAssertEqual(stream.activity.map(\.text), ["hello world"])
        XCTAssertFalse(try stream.receive(message(sequence: 5, text: "duplicate")))
        XCTAssertEqual(stream.activity.map(\.text), ["hello world"])
        XCTAssertTrue(try stream.receive(message("snapshot", sequence: 0, epoch: "b", eventID: "new")))
        XCTAssertEqual(stream.activity.map(\.id), ["new"])
        XCTAssertEqual(stream.cursor, SessionStreamCursor(epoch: "b", sequence: 0))
    }

    func testGapAndEpochChangeRequireSnapshot() throws {
        for changedEpoch in [false, true] {
            var stream = SessionStream(sessionID: "s")
            _ = try stream.receive(message("snapshot"))
            XCTAssertThrowsError(try stream.receive(message(sequence: changedEpoch ? 2 : 3, epoch: changedEpoch ? "b" : "a")))
            XCTAssertNil(stream.cursor)
            XCTAssertTrue(stream.activity.isEmpty)
        }
    }

    func testRejectWrongSessionAndEventWithoutSnapshot() throws {
        var stream = SessionStream(sessionID: "s")
        XCTAssertThrowsError(try stream.receive(message("snapshot", id: "other")))
        XCTAssertNil(stream.cursor)
        XCTAssertThrowsError(try stream.receive(message()))
        XCTAssertThrowsError(try stream.receive(message("snapshot", sequence: -1)))
    }
    func testStatusAndTranscriptInvalidation() throws {
        var stream = SessionStream(sessionID: "s")
        _ = try stream.receive(message("snapshot", sequence: 0))
        let status = #"{"version":1,"type":"event","sessionID":"s","epoch":"a","sequence":1,"kind":"status","payload":{"status":{"id":"s","title":"Test","state":"idle","workspace":"/","model":"test","permissions":"ask","queued":0,"jobs":0}}}"#
        XCTAssertTrue(try stream.receive(Data(status.utf8)))
        XCTAssertEqual(stream.status?.jobs, 0)
        let invalidation = #"{"version":1,"type":"event","sessionID":"s","epoch":"a","sequence":2,"kind":"transcript-changed","payload":{}}"#
        XCTAssertTrue(try stream.receive(Data(invalidation.utf8)))
        XCTAssertEqual(stream.cursor?.sequence, 2)
        XCTAssertEqual(stream.activity.count, 1)
        let error = #"{"version":1,"type":"error","sessionID":"s","error":"Unavailable"}"#
        XCTAssertThrowsError(try stream.receive(Data(error.utf8)))
    }


    func testBoundActivityAndText() throws {
        var stream = SessionStream(sessionID: "s")
        _ = try stream.receive(message("snapshot", sequence: 0))
        for index in 1...220 { _ = try stream.receive(message(sequence: index, eventID: "e\(index)")) }
        XCTAssertEqual(stream.activity.count, 200)
        _ = try stream.receive(message(sequence: 221, eventID: "large", text: String(repeating: "x", count: 100_000)))
        XCTAssertEqual(stream.activity.last?.text.utf8.count, 65_536)
        for index in 222...245 { _ = try stream.receive(message(sequence: index, eventID: "e\(index)", text: String(repeating: "x", count: 65_536))) }
        XCTAssertLessThanOrEqual(stream.activity.reduce(0) { $0 + $1.text.utf8.count }, 1_048_576)
    }

    func testActivityDoesNotRepublishOldStatusAndKeepsUpdateOrder() throws {
        var stream = SessionStream(sessionID: "s")
        _ = try stream.receive(message("snapshot", sequence: 0, eventID: "start"))
        XCTAssertTrue(stream.statusChanged)
        _ = try stream.receive(message(sequence: 1, eventID: "completed"))
        XCTAssertFalse(stream.statusChanged)
        XCTAssertTrue(stream.activityChanged)
        _ = try stream.receive(message(sequence: 2, eventID: "start"))
        XCTAssertEqual(stream.activity.map(\.id), ["completed", "start"])
        XCTAssertFalse(try stream.receive(message(sequence: 2)))
        XCTAssertFalse(stream.activityChanged)
        XCTAssertFalse(stream.statusChanged)
    }
}
