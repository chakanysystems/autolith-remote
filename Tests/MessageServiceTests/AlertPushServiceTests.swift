import XCTest
@testable import AutolithBridge
import ClientCore

final class AlertPushServiceTests: XCTestCase {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var file: URL { directory.appendingPathComponent("devices.json") }
        let token = String(repeating: "ab", count: 32)
        let host = "https://computer.example"
        var object: [String: Any] { ["pushToken": token, "host": host] }
        var date = Date(timeIntervalSince1970: 1_000_000)
        var working = true
        var enabled = true
        var deleted = false
        var failTranscript = false
        var status = 200
        var identities: [String] = []
        var duringSend: (() throws -> Void)?
        var service: AlertPushService!

        init() throws {
            service = try AlertPushService(file: file, enabled: { [unowned self] in self.enabled }, sender: { [unowned self] payload, _, identity in
                XCTAssertEqual(payload["notificationID"] as? String, identity)
                self.identities.append(identity)
                try self.duringSend?()
                return self.status
            }, call: { [unowned self] request in
                if request["operation"] as? String == "list" {
                    if self.deleted { return ["sessions": []] }
                    return ["sessions": [["id": "s", "state": self.working ? "working" : "idle"]]]
                }
                if self.failTranscript { throw NSError(domain: "test", code: 1) }
                return ["events": [["id": "u", "role": "user", "text": "question"], ["id": "a", "role": "assistant", "text": "answer"]]]
            }, now: { [unowned self] in self.date }, startTimer: false)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func prepareCompletion() async throws {
            try service.register(object)
            await service.pollOnce()
            working = false
        }
        func stored() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        }
    }

    func testPayloadCapsTotalUTF8IncludingEscapingAndUnicode() throws {
        for text in [String(repeating: "👨‍👩‍👧‍👦", count: 1000), String(repeating: "\u{0001}\"\\", count: 2000), "a" + String(repeating: "\u{0301}", count: 10000)] {
            let payload = try AlertPushService.payload(host: "https://computer.example/" + String(repeating: "h", count: 450), sessionID: String(repeating: "s", count: 256), eventID: String(repeating: "e", count: 256), title: text, text: text)
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertLessThanOrEqual(data.count, 4096)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
        XCTAssertThrowsError(try AlertPushService.payload(host: String(repeating: "h", count: 513), sessionID: "s", eventID: "e", title: "title", text: "text"))
        XCTAssertThrowsError(try AlertPushService.payload(host: "https://computer.example", sessionID: String(repeating: "🦊", count: 65), eventID: "e", title: "title", text: "text"))
        XCTAssertThrowsError(try AlertPushService.payload(host: "https://computer.example", sessionID: String(repeating: "\u{0001}", count: 256), eventID: String(repeating: "\u{0001}", count: 256), title: "", text: ""))
    }

    func testDeletedSessionPrunesDeliveredAndWorkingProgress() async throws {
        let f = try Fixture()
        try await f.prepareCompletion()
        await f.service.pollOnce()
        let before = try XCTUnwrap(f.stored()[f.token] as? [String: Any])
        XCTAssertEqual((before["delivered"] as? [String: String])?["s"], "a")
        f.deleted = true
        await f.service.pollOnce()
        let after = try XCTUnwrap(f.stored()[f.token] as? [String: Any])
        XCTAssertEqual(after["delivered"] as? [String: String], [:])
        XCTAssertEqual(after["working"] as? [String], [])
    }

    func testWatchBoundsTrackedSessionsWithoutMutatingOnFailure() throws {
        let f = try Fixture()
        try f.service.register(f.object)
        for index in 0..<256 { try f.service.watch("s-\(index)") }
        let before = try Data(contentsOf: f.file)
        XCTAssertThrowsError(try f.service.watch("overflow"))
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        XCTAssertLessThanOrEqual(before.count, 4 * 1024 * 1024)
    }
    func testRejectedDeliveryRetriesWithStableEventIdentity() async throws {
        let f = try Fixture()
        try await f.prepareCompletion()
        f.status = 503
        await f.service.pollOnce()
        f.status = 200
        await f.service.pollOnce()
        await f.service.pollOnce()
        XCTAssertEqual(f.identities.count, 2)
        XCTAssertEqual(Set(f.identities).count, 1)
        XCTAssertEqual(f.identities.first, NotificationEventIdentity.id(host: f.host, sessionID: "s", eventID: "a"))
    }

    func testRenewalDuringGoneReplyPreservesNewExpiryAndRetries() async throws {
        let f = try Fixture()
        try await f.prepareCompletion()
        f.status = 410
        f.duringSend = {
            f.date = f.date.addingTimeInterval(3600)
            try f.service.register(f.object)
        }
        await f.service.pollOnce()
        let device = try XCTUnwrap(f.stored()[f.token] as? [String: Any])
        let expires = try XCTUnwrap(device["expires"] as? Double)
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: expires), f.date.addingTimeInterval(7 * 86400))
        f.duringSend = nil
        f.status = 200
        await f.service.pollOnce()
        XCTAssertEqual(f.identities.count, 2)
    }

    func testRevocationDuringSendCannotResurrectRegistration() async throws {
        let f = try Fixture()
        try await f.prepareCompletion()
        f.duringSend = { try f.service.unregister(f.object) }
        await f.service.pollOnce()
        f.duringSend = nil
        await f.service.pollOnce()
        XCTAssertTrue(try f.stored().isEmpty)
        XCTAssertEqual(f.identities.count, 1)
    }

    func testRevocationIsHostScopedAndWorksWithAPNsDisabled() async throws {
        let f = try Fixture()
        try await f.prepareCompletion()
        try f.service.unregister(["pushToken": f.token, "host": "https://other.example"])
        XCTAssertEqual(try f.stored().count, 1)
        f.enabled = false
        try f.service.unregister(f.object)
        XCTAssertTrue(try f.stored().isEmpty)
        XCTAssertThrowsError(try f.service.register(f.object))
    }

    func testFailedWatchDoesNotRecordFalseProgressAndPollRecovers() async throws {
        let f = try Fixture()
        try await f.prepareCompletion()
        f.failTranscript = true
        XCTAssertThrowsError(try f.service.watch("s"))
        await f.service.pollOnce()
        XCTAssertTrue(f.identities.isEmpty)
        f.failTranscript = false
        await f.service.pollOnce()
        XCTAssertEqual(f.identities.count, 1)
    }
}
