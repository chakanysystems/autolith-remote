import XCTest
@testable import ClientCore

final class OutboxDeliveryStateTests: XCTestCase {
    private func receipt(_ state: String) -> Event {
        Event(id: "outbox-" + UUID().uuidString, role: "user", tool: "", text: "Question",
              timestamp: 100, deliveryState: state, dispatchAt: 115)
    }

    func testOnlyKnownPreparationFailureOffersRetry() {
        for state in ["queued", "preparing", "dispatching", "uncertain", "sent", "failed"] {
            let event = receipt(state)
            XCTAssertEqual(event.canRetryDelivery, state == "failed")
            XCTAssertEqual(event.canAbandonDelivery, ["queued", "failed", "uncertain"].contains(state))
            XCTAssertEqual(event.isDeliveryPending, ["queued", "preparing", "dispatching"].contains(state))
        }
        let executed = Event(id: "42", role: "user", tool: "", text: "Question", deliveryState: "failed")
        XCTAssertFalse(executed.canRetryDelivery)
        XCTAssertFalse(executed.canAbandonDelivery)
    }

    func testDurableAcceptanceIncludesActivePreparationAndHandoff() throws {
        for state in ["queued", "preparing", "dispatching", "sent"] {
            let event = receipt(state)
            XCTAssertEqual(try SiriMessageReceipt.accepted(events: [event], requestID: event.outboxRequestID!, text: event.text), event)
        }
        for state in ["failed", "uncertain", "retired", "missing"] {
            let event = receipt(state)
            XCTAssertThrowsError(try SiriMessageReceipt.accepted(events: [event], requestID: event.outboxRequestID!, text: event.text))
        }
    }

    func testFailedPreparationDoesNotHideLatestExecutedAnswer() {
        let prompt = Event(id: "1", role: "user", tool: "", text: "Earlier", timestamp: 10)
        let answer = Event(id: "2", role: "assistant", tool: "", text: "Answer", timestamp: 11)
        XCTAssertEqual(SiriContent.latestAnswerEvent(in: [prompt, answer, receipt("failed")]), answer)
        for state in ["queued", "preparing", "dispatching", "uncertain"] {
            XCTAssertNil(SiriContent.latestAnswerEvent(in: [prompt, answer, receipt(state)]))
        }
    }
}
