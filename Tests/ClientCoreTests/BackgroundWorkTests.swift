import XCTest
@testable import ClientCore

final class BackgroundWorkTests: XCTestCase {
    @MainActor func testCPUWorkLeavesMainActorAndReturnsForPublication() async throws {
        let ranOnMainThread = try await BackgroundWork.run {
            Thread.isMainThread
        }
        XCTAssertFalse(ranOnMainThread)
        XCTAssertTrue(Thread.isMainThread)
    }

    func testCancellationReachesRunningWorker() async throws {
        let started = expectation(description: "Background operation started")
        let work = Task {
            try await BackgroundWork.run {
                started.fulfill()
                let deadline = Date().addingTimeInterval(3)
                while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                try Task.checkCancellation()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        work.cancel()
        do { try await work.value; XCTFail("Cancelled work must not publish a result") }
        catch is CancellationError { }
    }

    @MainActor func testPreparedMarkdownAndRewritesAreProducedOffMain() async throws {
        let prepared = try await BackgroundWork.run {
            XCTAssertFalse(Thread.isMainThread)
            var cache = CachedTranscript(revision: "a", events: [], accessed: Date())
            try cache.reconcile(revision: "b", base: nil, order: nil,
                                changes: [Event(id: "1", role: "assistant", tool: "", text: "**old**")], unchanged: false)
            try cache.reconcile(revision: "c", base: "b", order: ["2"],
                                changes: [Event(id: "2", role: "assistant", tool: "", text: "**new**\nline")], unchanged: false)
            return cache
        }
        XCTAssertNil(prepared.presentations["1"])
        #if canImport(Darwin)
        XCTAssertEqual(prepared.presentations["2"]?.markdown.map { String($0.characters) }, "new\nline")
        #else
        XCTAssertEqual(prepared.presentations["2"]?.markdown.map { String($0.characters) }, "**new**\nline")
        #endif
        XCTAssertNotNil(prepared.byteCost)
        XCTAssertEqual(prepared.shareText, "assistant:\n**new**\nline")
        let restored = try JSONDecoder().decode(CachedTranscript.self, from: JSONEncoder().encode(prepared))
        XCTAssertTrue(restored.presentations.isEmpty, "Platform presentation values are regenerated, not persisted")
    }

    func testIndexPlanHandlesRewritesDeletionsAndEvictedTranscripts() async throws {
        let host = "https://computer.example"
        let session = Session(id: "s", title: "Test", state: "idle", workspace: "/test", model: "test", permissions: "ask", queued: 0, jobs: 0, updatedAt: 100)
        let old = Event(id: "1", role: "assistant", tool: "", text: "old", timestamp: 100)
        let removed = Event(id: "2", role: "assistant", tool: "", text: "deleted", timestamp: 101)
        let changed = Event(id: "1", role: "assistant", tool: "", text: "rewritten", timestamp: 100)
        let known = [old, removed].map { SiriMessageIdentity(host: host, sessionID: "s", eventID: $0.id).id }
        let plan = try await BackgroundWork.run {
            SiriMessageIndexPlan(host: host, sessions: [session], events: ["s": [changed]], known: known,
                                 indexedEvents: [host + "#s": ["1": old, "2": removed]], indexedSessions: [host + "#s": session])
        }
        XCTAssertEqual(plan.removed, [known[1]])
        XCTAssertEqual(plan.batches.first?.changed, [changed])
        XCTAssertEqual(Set(plan.batches.first?.byID.keys.map { $0 } ?? []), ["1"])
        let evicted = SiriMessageIndexPlan(host: host, sessions: [session], events: [:], known: known, indexedEvents: [:], indexedSessions: [:])
        XCTAssertTrue(evicted.removed.isEmpty)
        let deleted = SiriMessageIndexPlan(host: host, sessions: [], events: [:], known: known, indexedEvents: [:], indexedSessions: [:])
        XCTAssertEqual(Set(deleted.removed), Set(known))
    }
}
