import XCTest
@testable import AutolithBridge

final class PushServiceTests: XCTestCase {
    func testAbsentAPNsConfigurationDoesNotReadAKeyOrEnablePush() throws {
        let service = try PushService(environment: [:], snapshot: { Data() })
        XCTAssertFalse(service.enabled)
    }

    func testSameTokenRenewalSurvivesStaleGoneReplyAndOriginalExpiry() async throws {
        final class State {
            var date = Date(timeIntervalSince1970: 1_000_000)
            var calls = 0
            var service: PushService!
        }
        let state = State()
        let registration: [String: Any] = ["activityId": "activity", "pushToken": String(repeating: "ab", count: 32)]
        let sessions = Data(#"{"sessions":[{"id":"s","title":"Work","state":"working","workspace":"/w","model":"m","permissions":"ask","queued":0,"jobs":0}]}"#.utf8)
        state.service = PushService(snapshot: { sessions }, sender: { [unowned state] _, _ in
            state.calls += 1
            if state.calls == 1 {
                state.date = state.date.addingTimeInterval(7 * 3600)
                try state.service.register(registration)
                return 410
            }
            return 200
        }, now: { [unowned state] in state.date })
        try state.service.register(registration)
        await state.service.pollOnce()
        state.date = state.date.addingTimeInterval(2 * 3600)
        await state.service.pollOnce()
        XCTAssertEqual(state.calls, 2)
    }
}
