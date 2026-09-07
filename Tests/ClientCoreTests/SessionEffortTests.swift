import XCTest
@testable import ClientCore

final class SessionEffortTests: XCTestCase {
    private func session(_ fields: String = "") throws -> Session {
        let json = """
        {"id":"s","title":"Test","state":"working","workspace":"/test","model":"test-model","permissions":"ask","queued":0,"jobs":0\(fields)}
        """
        return try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    func testEffortMetadataIsOptionalForOlderBackends() throws {
        let value = try session()
        XCTAssertNil(value.effort)
        XCTAssertNil(value.supportedEfforts)
        XCTAssertNil(value.commandForEffort("high"))
    }

    func testEffortChoicesComeFromTheSession() throws {
        let value = try session(#", "effort":"high","supportedEfforts":["low","high"]"#)
        XCTAssertEqual(value.effort, "high")
        XCTAssertEqual(value.supportedEfforts, ["low", "high"])
        XCTAssertEqual(value.commandForEffort("low"), #"/effort "low""#)
        XCTAssertNil(value.commandForEffort("max"))
        XCTAssertNil(value.commandForEffort(""))
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }

    func testEffortCommandEscapesQuotedArguments() throws {
        var value = try session()
        value.supportedEfforts = ["quoted\"value", "back\\slash"]
        XCTAssertEqual(value.commandForEffort("quoted\"value"), #"/effort "quoted\"value""#)
        XCTAssertEqual(value.commandForEffort("back\\slash"), #"/effort "back\\slash""#)
    }

    func testStoppedSessionsDoNotSendEffortChanges() {
        var value = Session(id: "s", title: "Stopped", state: "stopped", workspace: "/test", model: "test", permissions: "ask", queued: 0, jobs: 0, updatedAt: nil)
        value.supportedEfforts = ["high"]
        XCTAssertNil(value.commandForEffort("high"))
    }

    func testPartialStreamStatusPreservesEffortForSameModel() throws {
        let current = try session(#", "effort":"medium","supportedEfforts":["low","medium","high"]"#)
        let merged = current.mergingStreamStatus(try session())
        XCTAssertEqual(merged.effort, "medium")
        XCTAssertEqual(merged.supportedEfforts, current.supportedEfforts)
        XCTAssertEqual(current.mergingStreamStatus(try session(#", "effort":"high""#)).effort, "high")
        let unsupported = try session(#", "supportedEfforts":[]"#)
        XCTAssertNil(current.mergingStreamStatus(unsupported).effort)
        let changed = Session(id: "s", title: "Test", state: "working", workspace: "/test", model: "other", permissions: "ask", queued: 0, jobs: 0, updatedAt: nil)
        XCTAssertNil(current.mergingStreamStatus(changed).effort)
    }
}
