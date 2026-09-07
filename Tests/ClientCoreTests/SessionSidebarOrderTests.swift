import XCTest
@testable import ClientCore

final class SessionSidebarOrderTests: XCTestCase {
    private func session(_ id: String, updated: Double?, workspace: String = "/project", jobs: Int = 0) -> Session {
        Session(id: id, title: "Session", state: jobs > 0 ? "working" : "idle", workspace: workspace,
                model: "test", permissions: "ask", queued: 0, jobs: jobs, updatedAt: updated)
    }

    func testOlderSessionsDiscoveredAfterCacheRestoreStayBelowRecentSessions() {
        let cached = [session("recent", updated: 100)]
        XCTAssertEqual(SessionSidebarOrder.ordered(cached).map(\.id), ["recent"])
        let refreshed = cached + [session("old", updated: 1), session("unknown", updated: nil)]
        XCTAssertEqual(SessionSidebarOrder.ordered(refreshed).map(\.id), ["recent", "old", "unknown"])
    }

    func testNewSavedActivityMovesSessionButStatusAloneDoesNot() {
        let first = [session("a", updated: 1), session("b", updated: 2)]
        XCTAssertEqual(SessionSidebarOrder.ordered(first).map(\.id), ["b", "a"])
        let status = [session("a", updated: 1, jobs: 3), first[1]]
        XCTAssertEqual(SessionSidebarOrder.ordered(status).map(\.id), ["b", "a"])
        let active = [session("a", updated: 9), first[1]]
        XCTAssertEqual(SessionSidebarOrder.ordered(active).map(\.id), ["a", "b"])
        XCTAssertEqual(SessionSidebarOrder.ordered([active[0]]).map(\.id), ["a"])
        XCTAssertTrue(SessionSidebarOrder.ordered([]).isEmpty)
    }

    func testProjectsSortByMostRecentSessionAndNormalizePaths() {
        let sessions = [session("old", updated: 1, workspace: "/a"),
                        session("new", updated: 50, workspace: "/z/"),
                        session("older", updated: 2, workspace: "/z"),
                        session("middle", updated: 20, workspace: "/b")]
        let sections = SessionSidebarOrder.sections(sessions, grouped: true)
        XCTAssertEqual(sections.map(\.id), ["/z", "/b", "/a"])
        XCTAssertEqual(sections[0].sessions.map(\.id), ["new", "older"])
        XCTAssertEqual(SessionSidebarOrder.sections(sessions, grouped: false).first?.sessions.map(\.id), ["new", "middle", "older", "old"])
    }

    func testTiesAndMissingDatesAreDeterministic() {
        let sessions = [session("b", updated: 1), session("a", updated: 1),
                        session("unknown", updated: nil), session("invalid", updated: .nan)]
        XCTAssertEqual(SessionSidebarOrder.ordered(sessions).map(\.id), ["a", "b", "invalid", "unknown"])
    }

    func testStreamWithoutTimestampPreservesRecencyEvenWhenModelChanges() {
        let current = session("s", updated: 100)
        let heartbeat = session("s", updated: nil, jobs: 2)
        XCTAssertEqual(current.mergingStreamStatus(heartbeat).updatedAt, 100)
        XCTAssertEqual(current.mergingStreamStatus(session("s", updated: 120)).updatedAt, 120)
        let changedModel = Session(id: "s", title: "Session", state: "idle", workspace: "/project",
                                   model: "other", permissions: "ask", queued: 0, jobs: 0, updatedAt: nil)
        XCTAssertEqual(current.mergingStreamStatus(changedModel).updatedAt, 100)
        XCTAssertNil(current.mergingStreamStatus(session("different", updated: nil)).updatedAt)
    }
}
