import XCTest
@testable import AutolithBridge
@testable import ClientCore
@testable import BridgeCore

final class MessageServiceTests: XCTestCase {
    func testUncertainReceiptDoesNotHideLaterExecutedAnswer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try MessageService(file: directory.appendingPathComponent("outbox.json"), startTimer: false) { _ in [:] }
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
        let service = try MessageService(file: directory.appendingPathComponent("outbox.json"), startTimer: false) { request in
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
    func testFailuresBeforeTellBackOffAndCanRetryWithoutDuplicateHandoff() throws {
        for failure in ["list", "resume", "missing-session", "wrong-resume-id"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var failing = true
            var tells: [String] = []
            let service = try MessageService(file: directory.appendingPathComponent("outbox.json"), startTimer: false) { request in
                let operation = request["operation"] as? String ?? ""
                if failing && operation == failure { throw BridgeError.invalid("Injected backend failure") }
                if operation == "list" {
                    return ["sessions": failing && failure == "missing-session" ? [] : [["id": "s", "workspace": "/w", "state": "stopped"]]]
                }
                if operation == "resume" { return ["id": failing && failure == "wrong-resume-id" ? "other" : "s"] }
                if operation == "tell" { tells.append(request["message"] as? String ?? "") }
                return [:]
            }
            let id = UUID().uuidString
            _ = try service.outbox.enqueue(id: id, sessionID: "s", workspace: "/w", text: "question", now: 100)
            var time = 115.0
            for attempt in 1...5 {
                service.dispatchNext(now: time)
                XCTAssertEqual(service.outbox.message(id)?.attempts, attempt)
                XCTAssertTrue(tells.isEmpty)
                service.dispatchNext(now: time + 1)
                XCTAssertEqual(service.outbox.message(id)?.attempts, attempt)
                time = try XCTUnwrap(service.outbox.message(id)?.dispatchAt)
            }
            XCTAssertEqual(service.outbox.message(id)?.state, "failed")
            let result = try XCTUnwrap(service.handle(["operation": "message-retry", "id": "s", "eventID": "outbox-" + id]))
            XCTAssertEqual((result["events"] as? [[String: Any]])?.first?["deliveryState"] as? String, "queued")
            failing = false
            time = try XCTUnwrap(service.outbox.message(id)?.dispatchAt)
            service.dispatchNext(now: time)
            service.dispatchNext(now: time + 1)
            XCTAssertEqual(tells, ["Question from Siri:\nquestion"])
            XCTAssertEqual(service.outbox.message(id)?.state, "sent")
        }
    }

    func testTellFailureIsNotRetriedAndCanBeAbandonedWithPermanentReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var tells = 0
        let service = try MessageService(file: directory.appendingPathComponent("outbox.json"), startTimer: false) { request in
            if request["operation"] as? String == "list" { return ["sessions": [["id": "s", "state": "running"]]] }
            tells += 1
            throw BridgeError.invalid("The response was lost after tell reached the backend")
        }
        let id = UUID().uuidString, eventID = "outbox-" + id
        _ = try service.outbox.enqueue(id: id, sessionID: "s", workspace: "/w", text: "q", now: 100)
        service.dispatchNext(now: 115)
        XCTAssertEqual(service.outbox.message(id)?.state, "uncertain")
        service.dispatchNext(now: 10000)
        XCTAssertEqual(tells, 1)
        XCTAssertThrowsError(try service.handle(["operation": "message-retry", "id": "s", "eventID": eventID]))
        XCTAssertThrowsError(try service.handle(["operation": "message-abandon", "id": "other", "eventID": eventID]))
        _ = try service.handle(["operation": "message-abandon", "id": "s", "eventID": eventID])
        let receipt = try XCTUnwrap(service.handle(["operation": "message-receipt", "requestID": id]))
        XCTAssertEqual(receipt["state"] as? String, "retired")
        XCTAssertThrowsError(try service.outbox.enqueue(id: id, sessionID: "s", workspace: "/w", text: "q"))
    }

    func testRequestScopedBackendAndMutationDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try MessageService(file: directory.appendingPathComponent("outbox.json"), startTimer: false) { _ in
            XCTFail("Used server backend instead of the request-scoped backend")
            return [:]
        }
        let id = UUID().uuidString
        var backendCalls = 0
        let request: ([String: Any]) throws -> [String: Any] = { _ in
            backendCalls += 1
            return ["sessions": [["id": "s", "workspace": "/w"]]]
        }
        XCTAssertThrowsError(try service.handle(["operation": "message-send", "id": "s", "requestID": id, "text": "q"], request: request,
                                               beforeMutation: { throw BridgeError.invalid("Deadline expired") }))
        XCTAssertEqual(backendCalls, 1)
        XCTAssertNil(service.outbox.message(id))
        _ = try service.handle(["operation": "message-send", "id": "s", "requestID": id, "text": "q"], request: request)
        XCTAssertEqual(service.outbox.message(id)?.state, "queued")
    }

    func testFailedClaimPersistenceRecoversWithoutSendingUntilDurable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var tells = 0
        let service = try MessageService(file: directory.appendingPathComponent("outbox.json"), startTimer: false) { request in
            if request["operation"] as? String == "list" { return ["sessions": [["id": "s", "state": "running"]]] }
            tells += 1
            return [:]
        }
        let id = UUID().uuidString
        _ = try service.outbox.enqueue(id: id, sessionID: "s", workspace: "/w", text: "q", now: 100)
        service.outbox.persist = { data, file in
            try DurableJSONFile.write(data, to: file) { stage in
                if stage == .renamed { throw BridgeError.invalid("Injected directory sync failure") }
            }
        }
        service.dispatchNext(now: 115)
        XCTAssertEqual(service.outbox.message(id)?.state, "preparing")
        service.dispatchNext(now: 116)
        XCTAssertEqual(tells, 0)
        service.outbox.persist = { try DurableJSONFile.write($0, to: $1) }
        service.dispatchNext(now: 117)
        XCTAssertEqual(service.outbox.message(id)?.state, "queued")
        XCTAssertEqual(tells, 0)
        service.dispatchNext(now: 147)
        XCTAssertEqual(tells, 1)
        XCTAssertEqual(service.outbox.message(id)?.state, "sent")
    }
    func testSuccessfulTellWithFailedReceiptPersistenceNeverReplays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var tells = 0, failPersistence = false
        let service = try MessageService(file: directory.appendingPathComponent("outbox.json"), startTimer: false) { request in
            if request["operation"] as? String == "list" { return ["sessions": [["id": "s", "state": "running"]]] }
            tells += 1
            failPersistence = true
            return [:]
        }
        let id = UUID().uuidString
        _ = try service.outbox.enqueue(id: id, sessionID: "s", workspace: "/w", text: "q", now: 100)
        service.outbox.persist = { data, file in
            if failPersistence { throw BridgeError.invalid("Injected storage outage after tell") }
            try DurableJSONFile.write(data, to: file)
        }
        service.dispatchNext(now: 115)
        XCTAssertEqual(tells, 1)
        XCTAssertEqual(service.outbox.message(id)?.state, "dispatching")
        failPersistence = false
        service.dispatchNext(now: 116)
        XCTAssertEqual(service.outbox.message(id)?.state, "uncertain")
        XCTAssertEqual(tells, 1)
        XCTAssertThrowsError(try service.outbox.retry(id))
    }
}
