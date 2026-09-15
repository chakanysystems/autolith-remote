import XCTest
@testable import ClientCore

final class SiriMessageIdentityTests: XCTestCase {
    func testMessageIdentityIncludesHostSessionAndDurableEvent() {
        let identity = SiriMessageIdentity(host: "https://computer.example", sessionID: "session/#λ", eventID: "84")
        XCTAssertEqual(SiriMessageIdentity(id: identity.id), identity)
        XCTAssertNotEqual(identity.id, SiriMessageIdentity(host: "https://other.example", sessionID: identity.sessionID, eventID: "84").id)
        XCTAssertNotEqual(identity.id, SiriMessageIdentity(host: identity.host, sessionID: "other", eventID: "84").id)
        XCTAssertNil(SiriMessageIdentity(id: "not an ID"))
    }

    func testDatesUseWireTimeAndRejectLocalOrToolRecords() throws {
        let event = try JSONDecoder().decode(Event.self, from: Data(#"{"id":"4","role":"assistant","tool":"","text":"Answer","timestamp":123}"#.utf8))
        XCTAssertEqual(SiriMessageIdentity.date(for: event)?.timeIntervalSince1970, 123)
        for invalid in [
            Event(id: "4", role: "assistant", tool: "", text: "Answer"),
            Event(id: "local-1", role: "assistant", tool: "", text: "Answer", timestamp: 123),
            Event(id: "5", role: "tool", tool: "shell", text: "Private", timestamp: 123),
            Event(id: "6", role: "assistant", tool: "", text: " ", timestamp: 123),
            Event(id: "7", role: "assistant", tool: "", text: "Answer", timestamp: .infinity)
        ] { XCTAssertNil(SiriMessageIdentity.date(for: invalid)) }
    }

    func testOlderCompanionResponseStillDecodesWithoutInventingDate() throws {
        let event = try JSONDecoder().decode(Event.self, from: Data(#"{"id":"4","role":"assistant","tool":"","text":"Answer"}"#.utf8))
        XCTAssertNil(event.timestamp)
    }

    func testLatestAnswerKeepsEventIdentityAndDoesNotUseEarlierTurn() {
        let answer = Event(id: "2", role: "assistant", tool: "", text: "Answer", timestamp: 123)
        XCTAssertEqual(SiriContent.latestAnswerEvent(in: [answer])?.id, "2")
        XCTAssertNil(SiriContent.latestAnswerEvent(in: [answer, Event(id: "3", role: "user", tool: "", text: "Next", timestamp: 124)]))
    }
}
