import XCTest
@testable import ClientCore

final class SiriContentTests: XCTestCase {
    func testDictationCannotBecomeLocalCodeOrCommand() throws {
        for question in ["/model luna", "(quit)", "  (delete-file \"x\")  ", "Why is λ failing?"] {
            let message = try SiriContent.question(question)
            XCTAssertFalse(message.hasPrefix("/"))
            XCTAssertFalse(message.hasPrefix("("))
            XCTAssertTrue(message.contains(question.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        XCTAssertThrowsError(try SiriContent.question(" \n "))
    }
    func testPreviousAnswerIsNotReadForAnUnansweredQuestion() {
        let events = [Event(id: "1", role: "user", tool: "", text: "Old question"),
                      Event(id: "2", role: "assistant", tool: "", text: "Old answer"),
                      Event(id: "3", role: "user", tool: "", text: "New question"),
                      Event(id: "4", role: "tool", tool: "shell", text: "Private tool output")]
        XCTAssertNil(SiriContent.latestAnswer(in: events))
        XCTAssertEqual(SiriContent.latestAnswer(in: events + [Event(id: "5", role: "assistant", tool: "", text: "New answer")]), "New answer")
    }
}
