import XCTest
@testable import ClientCore

final class SiriConversationSelectionTests: XCTestCase {
    private func session(_ id: String, state: String = "idle", updated: Double? = nil) -> Session {
        Session(id: id, title: id, state: state, workspace: "/work", model: "", permissions: "ask", queued: 0, jobs: 0, updatedAt: updated)
    }

    func testStatusKeepsRememberedConversationInsteadOfSwitchingToNewerTask() {
        let old = session("asked-about", updated: 1)
        let new = session("another-task", updated: 100)
        XCTAssertEqual(SiriConversationSelection.latest(in: [new, old], preferredID: old.id)?.id, old.id)
    }

    func testNoRememberedConversationUsesRecencyWithStableTieBreak() {
        let sessions = [session("unknown"), session("b", updated: 2), session("a", updated: 2)]
        XCTAssertEqual(SiriConversationSelection.latest(in: sessions, preferredID: nil)?.id, "a")
        XCTAssertNil(SiriConversationSelection.latest(in: [], preferredID: "deleted"))
    }

    func testSelectionNeverEscapesFilteredWorkspace() {
        let allowed = session("in-workspace", updated: 1)
        XCTAssertEqual(SiriConversationSelection.latest(in: [allowed], preferredID: "other-workspace")?.id, allowed.id)
    }

    func testIdleStatusNamesTheConversationWithoutReadingZeroCounters() {
        let selected = session("Fix build")
        let message = SiriConversationSelection.progress(sessions: [selected], selected: selected)
        XCTAssertTrue(message.contains("Nothing is running."))
        XCTAssertTrue(message.contains(selected.title))
        XCTAssertFalse(message.contains("0"))
        XCTAssertTrue(SiriConversationSelection.progress(sessions: [session("active", state: "working"), selected], selected: selected).contains("One conversation is working."))
    }
}
