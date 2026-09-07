import XCTest
@testable import ClientCore

final class SiriMessageReadStateTests: XCTestCase {
    func testIncomingAndOutgoingDefaults() {
        XCTAssertFalse(Event(id: "1", role: "assistant", tool: "", text: "answer").hasBeenRead)
        XCTAssertTrue(Event(id: "2", role: "user", tool: "", text: "question").hasBeenRead)
        XCTAssertTrue(Event(id: "3", role: "assistant", tool: "", text: "answer", isRead: true).hasBeenRead)
    }

    @MainActor func testReadingRequiresAcknowledgement() async throws {
        let event = Event(id: "1", role: "assistant", tool: "", text: "answer", timestamp: 100)
        let acknowledgements: [Bool?] = [nil, false]
        for acknowledgement in acknowledgements {
            do {
                _ = try await SiriMessageReadState.markRead(event) { acknowledgement }
                XCTFail("Unconfirmed receipt must fail")
            } catch { XCTAssertFalse(event.hasBeenRead) }
        }
        let updated = try await SiriMessageReadState.markRead(event) { true }
        XCTAssertTrue(updated.hasBeenRead)
        XCTAssertFalse(event.hasBeenRead)
    }

    @MainActor func testReadingAnAlreadyReadEventDoesNotWrite() async throws {
        let event = Event(id: "1", role: "assistant", tool: "", text: "answer", timestamp: 100, isRead: true)
        _ = try await SiriMessageReadState.markRead(event) {
            XCTFail("Already read events do not need a receipt")
            return nil
        }
    }
}
