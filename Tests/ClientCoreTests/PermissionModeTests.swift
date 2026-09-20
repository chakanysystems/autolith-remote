import XCTest
@testable import ClientCore

final class PermissionModeTests: XCTestCase {
    private func session(permissions: String, state: String = "idle") -> Session {
        Session(id: "s", title: "Test", state: state, workspace: "/test", model: "test",
                permissions: permissions, queued: 0, jobs: 0)
    }

    func testStatusModesMapToCommandAndCreationArguments() {
        let expected: [(String, String)] = [
            ("ask", "ask"), ("auto", "auto"),
            ("sandboxed", "sandbox"), ("full-access", "full")
        ]
        XCTAssertEqual(PermissionMode.allCases.count, expected.count)
        for (status, argument) in expected {
            let value = session(permissions: status)
            guard let mode = value.permissionMode else {
                XCTFail("Unrecognized backend mode: \(status)")
                continue
            }
            XCTAssertEqual(mode.argument, argument)
            XCTAssertEqual(value.commandForPermissions(mode), "(permissions \"\(argument)\")")
        }
    }

    func testStoppedSessionsCannotChangePermissions() {
        for mode in PermissionMode.allCases {
            XCTAssertNil(session(permissions: "ask", state: "stopped").commandForPermissions(mode))
        }
    }

    func testUnknownStatusDoesNotImplyAKnownPermissionMode() {
        XCTAssertNil(session(permissions: "future-mode").permissionMode)
    }

    func testStreamStatusUpdatesPermissionMode() {
        let current = session(permissions: "ask")
        let updated = current.mergingStreamStatus(session(permissions: "full-access"))
        XCTAssertEqual(updated.permissionMode, .fullAccess)
    }
}
