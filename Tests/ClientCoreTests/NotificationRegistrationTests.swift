import XCTest
@testable import ClientCore

final class NotificationRegistrationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testRevocationRejectsInflightAcceptance() throws {
        var state = NotificationRegistration()
        state.receivedDeviceToken("token")
        let request = try XCTUnwrap(state.beginRemoteRegistration(host: "mac", now: start))
        XCTAssertEqual(state.revoke(host: "mac"), "token")
        XCTAssertFalse(state.finishRemoteRegistration(request, accepted: true, now: start))
        XCTAssertFalse(state.usesRemoteNotifications(host: "mac", now: start))
        XCTAssertNil(state.beginRemoteRegistration(host: "mac", now: start))
    }

    func testCredentialAndGenerationChangesInvalidateAcceptedAndPendingRegistration() throws {
        var state = NotificationRegistration()
        state.receivedDeviceToken("apns")
        let first = ConnectionContext(host: "mac", token: "credential-a", generation: 0)
        state.activate(context: first)
        let accepted = try XCTUnwrap(state.beginRemoteRegistration(host: "mac", now: start))
        XCTAssertTrue(state.finishRemoteRegistration(accepted, accepted: true, now: start))
        state.activate(context: ConnectionContext(host: "mac", token: "credential-b", generation: 0))
        XCTAssertFalse(state.usesRemoteNotifications(host: "mac", now: start))
        let pending = try XCTUnwrap(state.beginRemoteRegistration(host: "mac", now: start))
        state.activate(context: ConnectionContext(host: "mac", token: "credential-b", generation: 1))
        XCTAssertFalse(state.finishRemoteRegistration(pending, accepted: true, now: start))
        XCTAssertNotNil(state.beginRemoteRegistration(host: "mac", now: start))
    }

    func testRevokedContextCannotReregisterUntilSwitchCompletes() throws {
        var state = NotificationRegistration()
        state.receivedDeviceToken("apns")
        let first = ConnectionContext(host: "mac", token: "credential", generation: 0)
        state.activate(context: first)
        _ = state.beginRemoteRegistration(host: "mac", now: start)
        _ = state.revoke(host: "mac")
        state.activate(context: first)
        state.receivedDeviceToken("rotated-apns")
        XCTAssertNil(state.beginRemoteRegistration(host: "mac", now: start))
        state.activate(context: ConnectionContext(host: "mac", token: "credential", generation: 1))
        XCTAssertNotNil(state.beginRemoteRegistration(host: "mac", now: start))
    }
    func testEventIdentityIsBoundedAndUnambiguous() {
        let identity = NotificationEventIdentity.id(host: "h", sessionID: "s", eventID: "e")
        XCTAssertEqual(identity.utf8.count, 64)
        XCTAssertEqual(identity, NotificationEventIdentity.id(host: "h", sessionID: "s", eventID: "e"))
        XCTAssertNotEqual(NotificationEventIdentity.id(host: "h#s", sessionID: "x", eventID: "e"),
                          NotificationEventIdentity.id(host: "h", sessionID: "s#x", eventID: "e"))
        XCTAssertNotEqual(identity, NotificationEventIdentity.id(host: "h", sessionID: "s", eventID: "e2"))
    }

    func testRequestsOncePerEnabledLaunchAndWaitsForCallback() {
        var state = NotificationRegistration()
        XCTAssertFalse(state.requestDeviceToken(enabled: false, now: start))
        XCTAssertNil(state.beginRemoteRegistration(host: "mac-a", now: start))
        XCTAssertTrue(state.requestDeviceToken(enabled: true, now: start))
        XCTAssertFalse(state.requestDeviceToken(enabled: true, now: start))
        state.receivedDeviceToken("test-token-a")
        XCTAssertFalse(state.requestDeviceToken(enabled: true, now: start.addingTimeInterval(7200)))
        var nextLaunch = NotificationRegistration()
        XCTAssertNil(nextLaunch.token)
        XCTAssertTrue(nextLaunch.requestDeviceToken(enabled: true, now: start))
    }

    func testFailedDeviceRegistrationUsesBoundedBackoff() {
        var state = NotificationRegistration()
        var now = start
        XCTAssertTrue(state.requestDeviceToken(enabled: true, now: now))
        for delay in [2.0, 8.0, 30.0, 120.0] {
            XCTAssertEqual(state.deviceRegistrationFailed(now: now), delay)
            XCTAssertNil(state.deviceRegistrationFailed(now: now))
            XCTAssertFalse(state.requestDeviceToken(enabled: true, now: now.addingTimeInterval(delay - 0.01)))
            now = now.addingTimeInterval(delay)
            XCTAssertTrue(state.requestDeviceToken(enabled: true, now: now))
            XCTAssertFalse(state.requestDeviceToken(enabled: true, now: now))
        }
        XCTAssertNil(state.deviceRegistrationFailed(now: now))
        XCTAssertFalse(state.requestDeviceToken(enabled: true, now: now.addingTimeInterval(86400)))
    }

    func testDisabledRetryWaitsForEnableAndSuccessStopsRetries() {
        var state = NotificationRegistration()
        XCTAssertTrue(state.requestDeviceToken(enabled: true, now: start))
        XCTAssertEqual(state.deviceRegistrationFailed(now: start), 2)
        let later = start.addingTimeInterval(20)
        XCTAssertFalse(state.requestDeviceToken(enabled: false, now: later))
        XCTAssertTrue(state.requestDeviceToken(enabled: true, now: later))
        state.receivedDeviceToken("test-token-a")
        XCTAssertNil(state.deviceRegistrationFailed(now: later))
        XCTAssertFalse(state.requestDeviceToken(enabled: true, now: later))
    }

    func testRemoteRegistrationsArePerHostAndExpire() throws {
        var state = NotificationRegistration()
        state.receivedDeviceToken("test-token-a")
        let request = try XCTUnwrap(state.beginRemoteRegistration(host: "mac-a", now: start))
        XCTAssertNil(state.beginRemoteRegistration(host: "mac-a", now: start))
        XCTAssertFalse(state.usesRemoteNotifications(host: "mac-a", now: start))
        XCTAssertTrue(state.finishRemoteRegistration(request, accepted: true, now: start))
        XCTAssertTrue(state.usesRemoteNotifications(host: "mac-a", now: start))
        XCTAssertFalse(state.usesRemoteNotifications(host: "mac-b", now: start))
        let other = try XCTUnwrap(state.beginRemoteRegistration(host: "mac-b", now: start))
        XCTAssertTrue(state.finishRemoteRegistration(other, accepted: true, now: start))
        XCTAssertTrue(state.usesRemoteNotifications(host: "mac-a", now: start))
        XCTAssertNil(state.beginRemoteRegistration(host: "mac-a", now: start.addingTimeInterval(3599)))
        XCTAssertFalse(state.usesRemoteNotifications(host: "mac-a", now: start.addingTimeInterval(3600)))
        XCTAssertNotNil(state.beginRemoteRegistration(host: "mac-a", now: start.addingTimeInterval(3600)))
    }

    func testChangedTokenBypassesHostTimerAndRejectsStaleCompletion() throws {
        var state = NotificationRegistration()
        state.receivedDeviceToken("test-token-a")
        let accepted = try XCTUnwrap(state.beginRemoteRegistration(host: "mac-a", now: start))
        XCTAssertTrue(state.finishRemoteRegistration(accepted, accepted: true, now: start))
        let stale = try XCTUnwrap(state.beginRemoteRegistration(host: "mac-b", now: start))
        state.receivedDeviceToken("test-token-b")
        XCTAssertFalse(state.isCurrent(stale))
        XCTAssertFalse(state.usesRemoteNotifications(host: "mac-a", now: start))
        let changed = try XCTUnwrap(state.beginRemoteRegistration(host: "mac-a", now: start))
        XCTAssertEqual(changed.token, "test-token-b")
        XCTAssertTrue(state.isCurrent(changed))
        XCTAssertFalse(state.finishRemoteRegistration(stale, accepted: true, now: start))
        XCTAssertFalse(state.usesRemoteNotifications(host: "mac-b", now: start))
        XCTAssertTrue(state.finishRemoteRegistration(changed, accepted: true, now: start))
        state.receivedDeviceToken("test-token-b")
        XCTAssertTrue(state.usesRemoteNotifications(host: "mac-a", now: start))
        XCTAssertNil(state.beginRemoteRegistration(host: "mac-a", now: start))
    }

    func testTokenRotationBackCannotAcceptOldRequest() throws {
        var state = NotificationRegistration()
        state.receivedDeviceToken("test-token-a")
        let stale = try XCTUnwrap(state.beginRemoteRegistration(host: "mac-a", now: start))
        state.receivedDeviceToken("test-token-b")
        state.receivedDeviceToken("test-token-a")
        let current = try XCTUnwrap(state.beginRemoteRegistration(host: "mac-a", now: start))
        XCTAssertFalse(state.isCurrent(stale))
        XCTAssertFalse(state.finishRemoteRegistration(stale, accepted: true, now: start))
        XCTAssertTrue(state.finishRemoteRegistration(current, accepted: true, now: start))
    }

    func testRejectedRenewalEnablesLocalFallbackAndAllowsRetry() throws {
        var state = NotificationRegistration()
        state.receivedDeviceToken("test-token-a")
        let first = try XCTUnwrap(state.beginRemoteRegistration(host: "mac-a", now: start))
        XCTAssertTrue(state.finishRemoteRegistration(first, accepted: true, now: start))
        let later = start.addingTimeInterval(3600)
        let renewal = try XCTUnwrap(state.beginRemoteRegistration(host: "mac-a", now: later))
        // Both capability-disabled replies and RPC failures finish with accepted: false.
        XCTAssertFalse(state.finishRemoteRegistration(renewal, accepted: false, now: later))
        XCTAssertFalse(state.usesRemoteNotifications(host: "mac-a", now: later))
        XCTAssertNotNil(state.beginRemoteRegistration(host: "mac-a", now: later))
    }
}
