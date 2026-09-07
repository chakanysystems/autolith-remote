import XCTest
@testable import ClientCore

final class TranscriptUpdatesTests: XCTestCase {
    private func event(_ id: String, _ text: String = "text") -> Event {
        Event(id: id, role: "assistant", tool: "", text: text)
    }
    func testDeltaKeepsSequenceAndReplacesPendingOutbox() {
        let previous = [event("1"), event("2"), event("outbox-old")]
        let update = [event("2", "updated"), event("3"), event("outbox-new")]
        let merged = TranscriptUpdates.merge(previous, incoming: update, replacing: false)
        XCTAssertEqual(merged.map(\.id), ["1", "2", "3", "outbox-new"])
        XCTAssertEqual(merged[1].text, "updated")
        XCTAssertEqual(TranscriptUpdates.cursor(merged), 3)
    }
    func testFullSnapshotReplacesHistoryAndEmptyDeltaClearsPendingRows() {
        XCTAssertEqual(TranscriptUpdates.merge([event("1")], incoming: [event("local-0")], replacing: true).map(\.id), ["local-0"])
        XCTAssertEqual(TranscriptUpdates.merge([event("1"), event("outbox-old")], incoming: [], replacing: false).map(\.id), ["1"])
    }
}
