import XCTest
@testable import ClientCore

@MainActor final class SiriFollowUpTests: XCTestCase {
    private func session(state: String) -> Session {
        Session(id: "original", title: "Question", state: state, workspace: "/project", model: "", permissions: "ask", queued: 0, jobs: 0, updatedAt: nil)
    }
    func testLiveFollowUpOnlyTellsOriginalConversation() async throws {
        var requests: [[String: String]] = []
        try await SiriFollowUp.send(question: "(quit)", session: session(state: "idle")) { requests.append($0); return nil }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0]["operation"], "tell")
        XCTAssertEqual(requests[0]["id"], "original")
        XCTAssertEqual(requests[0]["message"], "Question from Siri:\n(quit)")
    }
    func testStoppedConversationResumesBeforeTell() async throws {
        var operations: [String] = []
        try await SiriFollowUp.send(question: "Explain further", session: session(state: "stopped")) {
            operations.append($0["operation"]!)
            XCTAssertEqual($0["id"], "original")
            return $0["operation"] == "resume" ? "original" : nil
        }
        XCTAssertEqual(operations, ["resume", "tell"])
    }
    func testResumeMismatchNeverSendsToNewConversation() async {
        var calls = 0
        do {
            try await SiriFollowUp.send(question: "Explain", session: session(state: "stopped")) { _ in calls += 1; return "different" }
            XCTFail("Expected mismatch")
        } catch { XCTAssertEqual(calls, 1) }
    }
    func testEmptyInputHasNoSideEffectsAndFailedDeliveryDoesNotRetry() async {
        var calls = 0
        do {
            try await SiriFollowUp.send(question: "  ", session: session(state: "stopped")) { _ in calls += 1; return nil }
            XCTFail("Expected empty input error")
        } catch { XCTAssertEqual(calls, 0) }
        do {
            try await SiriFollowUp.send(question: "Explain", session: session(state: "idle")) { _ in calls += 1; throw URLError(.timedOut) }
            XCTFail("Expected delivery error")
        } catch { XCTAssertEqual(calls, 1) }
    }
    func testRememberedConversationNeverCrossesHosts() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        SiriConversationMemory.remember(id: "original", host: "mac-a", defaults: defaults)
        XCTAssertEqual(SiriConversationMemory.identifier(host: "mac-a", defaults: defaults), "original")
        XCTAssertNil(SiriConversationMemory.identifier(host: "mac-b", defaults: defaults))
        SiriConversationMemory.remember(id: "read-session", host: "mac-a", defaults: defaults)
        XCTAssertEqual(SiriConversationMemory.identifier(host: "mac-a", defaults: defaults), "read-session")
    }
    func testReadingAnOlderConversationDoesNotMoveLastSentConversation() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        SiriConversationMemory.sent(id: "new", host: "mac-a", defaults: defaults)
        SiriConversationMemory.remember(id: "old", host: "mac-a", defaults: defaults)
        XCTAssertEqual(SiriConversationMemory.lastSentIdentifier(host: "mac-a", defaults: defaults), "new")
        XCTAssertEqual(SiriConversationMemory.identifier(host: "mac-a", defaults: defaults), "old")
        XCTAssertNil(SiriConversationMemory.lastSentIdentifier(host: "mac-b", defaults: defaults))
        SiriConversationMemory.sent(id: "other", host: "mac-b", defaults: defaults)
        XCTAssertEqual(SiriConversationMemory.lastSentIdentifier(host: "mac-a", defaults: defaults), "new")
    }
}
