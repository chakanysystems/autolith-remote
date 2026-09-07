import XCTest
@testable import BridgeCore

final class IdleSessionPolicyTests: XCTestCase {
    private func session(_ state: String = "idle", jobs: Int = 0, queued: Int = 0, revision: Double = 1) -> [String: Any] {
        ["id": "s", "state": state, "jobs": jobs, "queued": queued, "updatedAt": revision]
    }
    func testContinuousIdleAndNewActivity() {
        var policy = IdleSessionPolicy(timeout: 60)
        XCTAssertTrue(policy.candidates([session()], now: 0).isEmpty)
        XCTAssertTrue(policy.candidates([session()], now: 59).isEmpty)
        XCTAssertEqual(policy.candidates([session()], now: 60), ["s"])
        XCTAssertTrue(policy.candidates([session(revision: 2)], now: 61).isEmpty)
        policy.activity("s")
        XCTAssertTrue(policy.candidates([session(revision: 2)], now: 200).isEmpty)
    }
    func testWorkMissingSessionsAndFailedInventoryResetDeadline() {
        for busy in [session("active"), session("paused"), session(jobs: 1), session(queued: 1)] {
            var policy = IdleSessionPolicy(timeout: 60)
            _ = policy.candidates([session()], now: 0)
            XCTAssertTrue(policy.candidates([busy], now: 90).isEmpty)
            XCTAssertTrue(policy.candidates([session()], now: 91).isEmpty)
            XCTAssertTrue(policy.candidates([], now: 120).isEmpty)
            XCTAssertTrue(policy.candidates([session()], now: 200).isEmpty)
            policy.reset()
            XCTAssertTrue(policy.candidates([session()], now: 400).isEmpty)
        }
    }
    func testRestartedProcessGetsFreshIdlePeriod() {
        var policy = IdleSessionPolicy(timeout: 60)
        var first = session(); first["pid"] = 10
        var replacement = session(); replacement["pid"] = 11
        _ = policy.candidates([first], now: 0)
        XCTAssertTrue(policy.candidates([replacement], now: 90).isEmpty)
        XCTAssertEqual(policy.candidates([replacement], now: 150), ["s"])
    }
}
