import XCTest
@testable import ClientCore

final class ClientCoreTests: XCTestCase {
    func testFinishedActivityRetainsContextWithoutWorkingCounts() throws {
        let session = Session(id: "a", title: "Build app", state: "working", workspace: "/", model: "m", permissions: "ask", queued: 2, jobs: 3, updatedAt: 1)
        let finished = WorkSummary.from([session]).finished
        XCTAssertEqual(finished.sessions, 0)
        XCTAssertEqual(finished.tasks, 0)
        XCTAssertEqual(finished.queued, 0)
        XCTAssertEqual(finished.items.first?.title, "Build app")
        XCTAssertEqual(finished.items.first?.state, "idle")
        XCTAssertEqual(try JSONDecoder().decode(WorkSummary.self, from: JSONEncoder().encode(finished)), finished)
    }
    func testSummaryScalesWithoutGrowingPayload() throws {
        let sessions = (0..<200).map { index in
            Session(id: "s\(index)", title: String(repeating: "λ", count: 400), state: "working", workspace: "/project", model: "model", permissions: "ask", queued: 1, jobs: 2, updatedAt: Double(index))
        }
        let state = WorkSummary.from(sessions)
        XCTAssertEqual(state.sessions, 200)
        XCTAssertEqual(state.tasks, 400)
        XCTAssertEqual(state.queued, 200)
        XCTAssertEqual(state.items.map(\.id), ["s199", "s198", "s197"])
        XCTAssertLessThan(try JSONEncoder().encode(state).count, 3000)
    }
    func testSummaryExcludesIdleAndStoppedSessions() {
        let sessions = ["idle", "stopped", "active"].map {
            Session(id: $0, title: $0, state: $0, workspace: "/", model: "m", permissions: "ask", queued: 0, jobs: 0, updatedAt: 1)
        }
        XCTAssertEqual(WorkSummary.from(sessions).sessions, 1)
        XCTAssertEqual(WorkSummary.from(sessions).items.first?.id, "active")
    }
    func testCompletionAtNestedFormAndUnicodeCaret() {
        let text = "(list \"λ\" (mapc"
        let context = ComposerContext(text: text, caret: (text as NSString).length)
        XCTAssertEqual(context?.prefix, "(mapc")
        XCTAssertEqual((text as NSString).substring(with: context!.range), "(mapc")
        XCTAssertNil(ComposerContext(text: "(print \"(ma", caret: 11))
        XCTAssertNil(ComposerContext(text: "; (map", caret: 6))
        XCTAssertEqual(ComposerContext(text: "/mod", caret: 4)?.prefix, "/mod")
    }
    func testOldCompanionSessionStillDecodes() throws {
        let data = Data(#"{"id":"a","title":"a","state":"idle","workspace":"/","model":"m","permissions":"ask","queued":0,"jobs":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Session.self, from: data).updatedAt)
    }
}
