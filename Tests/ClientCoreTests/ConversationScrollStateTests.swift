import XCTest
@testable import ClientCore

final class ConversationScrollStateTests: XCTestCase {
    func testLargeReplyDoesNotDisableFollowingAtBottom() {
        var state = ConversationScrollState()
        state.geometryChanged(distanceFromBottom: 0)
        state.geometryChanged(distanceFromBottom: 20000)
        XCTAssertTrue(state.shouldFollow)
    }

    func testReadingOlderMessagesDoesNotJumpOnNewOutput() {
        var state = ConversationScrollState()
        state.userScrollChanged(active: true, distanceFromBottom: 0)
        state.geometryChanged(distanceFromBottom: 800)
        state.userScrollChanged(active: false, distanceFromBottom: 800)
        state.geometryChanged(distanceFromBottom: 20000)
        XCTAssertFalse(state.shouldFollow)
        state.geometryChanged(distanceFromBottom: 0)
        XCTAssertFalse(state.shouldFollow)
    }

    func testReturningToBottomResumesFollowingAfterGestureEnds() {
        var state = ConversationScrollState()
        state.userScrollChanged(active: true, distanceFromBottom: 800)
        state.geometryChanged(distanceFromBottom: 20)
        XCTAssertFalse(state.shouldFollow)
        state.userScrollChanged(active: false, distanceFromBottom: 20)
        XCTAssertTrue(state.shouldFollow)
    }

    func testHistoryStartsWithLatestPageAndPreservesStartOnAppend() {
        var history = ConversationHistoryWindow()
        let ids = (0..<250).map(String.init)
        history.update(ids)
        XCTAssertEqual(history.startIndex(in: ids), 150)

        let appended = (0..<260).map(String.init)
        history.update(appended)
        XCTAssertEqual(history.startIndex(in: appended), 150)
        XCTAssertEqual(history.firstID, "150")
    }

    func testEarlierHistoryLoadsOnePageAtATime() {
        var history = ConversationHistoryWindow()
        let ids = (0..<250).map(String.init)
        history.update(ids)
        history.showEarlier(ids)
        XCTAssertEqual(history.startIndex(in: ids), 50)
        history.showEarlier(ids)
        XCTAssertEqual(history.startIndex(in: ids), 0)
        history.showEarlier(ids)
        XCTAssertEqual(history.startIndex(in: ids), 0)
    }

    func testHistoryHandlesEmptyAndReplacedEvents() {
        var history = ConversationHistoryWindow()
        history.update((0..<250).map(String.init))
        let replacement = (300..<450).map(String.init)
        history.update(replacement)
        XCTAssertEqual(history.startIndex(in: replacement), 50)
        XCTAssertEqual(history.firstID, "350")

        history.update([])
        history.showEarlier([])
        XCTAssertNil(history.firstID)
        XCTAssertEqual(history.startIndex(in: []), 0)
        history.update(["new"])
        XCTAssertEqual(history.firstID, "new")
    }
}
