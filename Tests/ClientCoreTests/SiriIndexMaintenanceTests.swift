import XCTest
@testable import ClientCore

final class SiriIndexMaintenanceTests: XCTestCase {
    @MainActor func testFailedUpdateReportsItsErrorOnce() async {
        enum Failure: Error { case unavailable }
        var failures = 0
        await SiriIndexMaintenance.run(update: { throw Failure.unavailable }, failed: { error in
            XCTAssertTrue(error is Failure)
            failures += 1
        })
        XCTAssertEqual(failures, 1)
    }

    @MainActor func testSuccessfulUpdateDoesNotReportFailure() async {
        var updates = 0
        await SiriIndexMaintenance.run(update: { updates += 1 }, failed: { _ in XCTFail("Unexpected index failure") })
        XCTAssertEqual(updates, 1)
    }
}
