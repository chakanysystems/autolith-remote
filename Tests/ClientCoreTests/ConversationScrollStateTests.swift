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

    func testHistoryStaysBoundedAndPinsWhenReading() {
        var history = ConversationHistoryWindow()
        let ids = (0..<250).map(String.init)
        history.update(ids)
        XCTAssertEqual(history.startIndex(in: ids), 150)

        let appended = (0..<260).map(String.init)
        history.update(appended)
        XCTAssertEqual(history.startIndex(in: appended), 160)
        XCTAssertEqual(history.range(in: appended).count, 100)
        history.setFollowing(false, ids: appended)
        let later = (0..<1000).map(String.init)
        history.update(later)
        XCTAssertEqual(history.startIndex(in: later), 160)
        XCTAssertEqual(history.range(in: later).count, 100)
        history.showLatest(later)
        XCTAssertEqual(history.range(in: later), 900..<1000)
    }

    func testEarlierHistoryLoadsOnePageAtATime() {
        var history = ConversationHistoryWindow()
        let ids = (0..<250).map(String.init)
        history.update(ids)
        history.showEarlier(ids)
        XCTAssertEqual(history.startIndex(in: ids), 50)
        history.showEarlier(ids)
        XCTAssertEqual(history.startIndex(in: ids), 0)
        XCTAssertEqual(history.range(in: ids).count, 100)
        history.setFollowing(true, ids: ids)
        XCTAssertEqual(history.startIndex(in: ids), 0)
        history.showNewer(ids)
        XCTAssertEqual(history.range(in: ids), 100..<200)
        history.showNewer(ids)
        XCTAssertEqual(history.range(in: ids), 150..<250)
        XCTAssertTrue(history.followsLatest)
        history.showEarlier(ids)
        XCTAssertEqual(history.startIndex(in: ids), 50)
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
