import XCTest
@testable import ClientCore

final class CompletionNotificationsTests: XCTestCase {
    private func session(_ state: String) -> Session {
        Session(id: "session", title: "Task", state: state, workspace: "/work", model: "", permissions: "ask", queued: 0, jobs: 0, updatedAt: nil)
    }

    func testCompletionRequiresObservedWorkAndIsAcknowledgedOnce() throws {
        var state = CompletionNotifications()
        XCTAssertTrue(state.completed([session("idle")]).isEmpty)
        XCTAssertTrue(state.completed([session("working")]).isEmpty)
        let restored = try JSONDecoder().decode(CompletionNotifications.self, from: JSONEncoder().encode(state))
        state = restored
        XCTAssertEqual(state.completed([session("idle")]).map(\.id), ["session"])
        XCTAssertEqual(state.completed([session("idle")]).count, 1, "Retry when delivery has not succeeded")
        XCTAssertTrue(state.acknowledge(sessionID: "session", eventID: "2"))
        XCTAssertTrue(state.completed([session("idle")]).isEmpty)
        XCTAssertFalse(state.acknowledge(sessionID: "session", eventID: "2"))
    }

    func testCancelledQueueDoesNotAnnounceAnOldResponse() {
        var state = CompletionNotifications()
        state.baseline(sessionID: "session", events: [Event(id: "old", role: "assistant", tool: "", text: "Previous answer"), Event(id: "outbox", role: "user", tool: "", text: "Cancelled")])
        _ = state.completed([session("working")])
        XCTAssertEqual(state.completed([session("idle")]).count, 1)
        XCTAssertFalse(state.acknowledge(sessionID: "session", eventID: "old"))
        _ = state.completed([session("working")])
        XCTAssertTrue(state.completed([]).isEmpty)
        XCTAssertTrue(state.working.isEmpty)
    }

    func testFastAnswerIsNotMistakenForPreviousTurn() {
        var state = CompletionNotifications()
        state.baseline(sessionID: "session", events: [
            Event(id: "old", role: "assistant", tool: "", text: "Previous answer"),
            Event(id: "question", role: "user", tool: "", text: "Question"),
            Event(id: "answer", role: "assistant", tool: "", text: "New answer")
        ])
        _ = state.completed([session("working")])
        XCTAssertEqual(state.completed([session("idle")]).count, 1)
        XCTAssertTrue(state.acknowledge(sessionID: "session", eventID: "answer"))
    }
}
