import XCTest
@testable import ClientCore

final class SiriTraceTests: XCTestCase {
    func testTracePersistsBoundedOrderedEvents() async {
        await MainActor.run {
            let name = "SiriTraceTests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            for n in 0..<(SiriTrace.limit + 5) {
                SiriTrace.record("Prepared", sessionID: "session", count: n, hasResponse: true, defaults: defaults)
            }
            let entries = SiriTrace.entries(defaults: defaults)
            XCTAssertEqual(entries.count, SiriTrace.limit)
            XCTAssertEqual(entries.first?.count, 5)
            XCTAssertEqual(entries.last?.count, SiriTrace.limit + 4)
            XCTAssertEqual(entries.last?.sessionID, "session")
            XCTAssertEqual(entries.last?.hasResponse, true)
        }
    }

    func testInvalidSavedTraceDoesNotBlockNewEvents() async {
        await MainActor.run {
            let name = "SiriTraceTests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(Data("broken".utf8), forKey: SiriTrace.key)
            SiriTrace.record("Failed", errorCode: 7, defaults: defaults)
            XCTAssertEqual(SiriTrace.entries(defaults: defaults).count, 1)
            XCTAssertEqual(SiriTrace.entries(defaults: defaults).first?.errorCode, 7)
        }
    }
}
