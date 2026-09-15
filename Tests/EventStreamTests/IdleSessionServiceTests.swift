import XCTest
@testable import AutolithBridge

final class IdleSessionServiceTests: XCTestCase {
    private let inventory: [[String: Any]] = [
        ["id": "s", "state": "idle", "jobs": 0, "queued": 0, "updatedAt": 1.0, "pid": 10]
    ]

    func testIdleIntervalStartsWhenInventoryCompletes() {
        var now: TimeInterval = 0
        var stops = 0
        var firstInventory = true
        let service = IdleSessionService(timeout: 60, startTimer: false, clock: { now }) { request in
            if request["operation"] as? String == "list" {
                if firstInventory { now = 100; firstInventory = false }
                return ["sessions": self.inventory]
            }
            stops += 1
            return [:]
        }
        service.poll()
        now = 159
        service.poll()
        XCTAssertEqual(stops, 0)
        now = 160
        service.poll()
        XCTAssertEqual(stops, 1)
    }
    func testActivityDuringBlockedInventoryInvalidatesCandidateImmediately() {
        let listed = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        var block = false
        var stops = 0
        let service = IdleSessionService(timeout: 60, startTimer: false) { request in
            if request["operation"] as? String == "list" {
                if block { listed.signal(); _ = resume.wait(timeout: .now() + 3) }
                return ["sessions": self.inventory]
            }
            stops += 1
            return [:]
        }
        service.poll(now: 0)
        block = true
        let finished = expectation(description: "inventory completed")
        DispatchQueue.global().async { service.poll(now: 100); finished.fulfill() }
        XCTAssertEqual(listed.wait(timeout: .now() + 2), .success)
        service.activity("s")
        resume.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(stops, 0)
        block = false
        service.poll(now: 101)
        XCTAssertEqual(stops, 0)
        service.poll(now: 161)
        XCTAssertEqual(stops, 1)
    }

    func testActivityWhileEarlierStopBlocksSkipsLaterCandidate() {
        var service: IdleSessionService!
        var stopped: [String] = []
        let sessions = inventory + [["id": "t", "state": "idle", "jobs": 0, "queued": 0, "updatedAt": 1.0, "pid": 11]]
        service = IdleSessionService(timeout: 60, startTimer: false) { request in
            if request["operation"] as? String == "list" { return ["sessions": sessions] }
            let id = request["id"] as! String
            stopped.append(id)
            if id == "s" { service.activity("t") }
            return [:]
        }
        service.poll(now: 0)
        service.poll(now: 100)
        XCTAssertEqual(stopped, ["s"])
    }
}
