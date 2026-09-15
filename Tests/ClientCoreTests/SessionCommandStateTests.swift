import XCTest
@testable import ClientCore

final class SessionCommandStateTests: XCTestCase {
    func testCommandsAreIndependentAndDuplicateSendsAreRejected() throws {
        var state = SessionCommandState()
        let first = try XCTUnwrap(state.begin("a"))
        XCTAssertNil(state.begin("a"))
        XCTAssertNotNil(state.begin("b"))
        state.finish("a", token: first)
        XCTAssertFalse(state.contains("a"))
        XCTAssertTrue(state.contains("b"))
    }

    func testLateCompletionCannotReleaseNewConnectionCommand() throws {
        var state = SessionCommandState()
        let old = try XCTUnwrap(state.begin("a"))
        state.clear()
        let current = try XCTUnwrap(state.begin("a"))
        state.finish("a", token: old)
        XCTAssertTrue(state.contains("a"))
        state.finish("a", token: current)
        XCTAssertFalse(state.contains("a"))
    }
}
