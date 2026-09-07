import XCTest
@testable import ClientCore

final class SiriMessageReceiptTests: XCTestCase {
    func testOnlyMatchingDurableQueueAcknowledgementCountsAsAccepted() throws {
        let id = UUID().uuidString
        let event = Event(id: "outbox-" + id, role: "user", tool: "", text: "question", timestamp: 100, deliveryState: "queued", dispatchAt: 115)
        XCTAssertEqual(try SiriMessageReceipt.accepted(events: [event], requestID: id, text: "question").id, event.id)
        XCTAssertThrowsError(try SiriMessageReceipt.accepted(events: [], requestID: id, text: "question"))
        XCTAssertThrowsError(try SiriMessageReceipt.accepted(events: [event], requestID: UUID().uuidString, text: "question"))
        XCTAssertThrowsError(try SiriMessageReceipt.accepted(events: [event], requestID: id, text: "different"))
        var uncertain = event; uncertain.deliveryState = "uncertain"
        XCTAssertThrowsError(try SiriMessageReceipt.accepted(events: [uncertain], requestID: id, text: "question"))
    }
}
