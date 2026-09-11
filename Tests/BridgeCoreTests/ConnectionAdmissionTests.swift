import XCTest
@testable import BridgeCore

final class ConnectionAdmissionTests: XCTestCase {
    func testSlowHandshakesCannotReserveAuthenticatedCapacity() {
        var admission = ConnectionAdmission(pendingLimit: 2, authenticatedLimit: 1)
        let first = UUID(), second = UUID(), authorized = UUID()
        XCTAssertNil(admission.admit(first))
        XCTAssertNil(admission.admit(second))
        XCTAssertEqual(admission.admit(authorized), first)
        XCTAssertFalse(admission.authenticate(first))
        XCTAssertTrue(admission.authenticate(authorized))
        XCTAssertFalse(admission.authenticate(second))
        admission.remove(authorized)
        XCTAssertTrue(admission.authenticate(second))
    }

    func testPendingChurnDoesNotEvictAuthenticatedConnections() {
        var admission = ConnectionAdmission(pendingLimit: 1, authenticatedLimit: 1)
        let authorized = UUID()
        _ = admission.admit(authorized)
        XCTAssertTrue(admission.authenticate(authorized))
        for _ in 0..<100 {
            XCTAssertNotEqual(admission.admit(UUID()), authorized)
        }
        XCTAssertTrue(admission.authenticate(authorized))
        admission.remove(authorized)
        admission.remove(authorized)
        let next = UUID()
        _ = admission.admit(next)
        XCTAssertTrue(admission.authenticate(next))
    }
}
