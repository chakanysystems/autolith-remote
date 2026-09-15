import XCTest
@testable import ClientCore

private actor ConnectionTestGate {
    private var continuation: CheckedContinuation<Void, Error>?
    var waiting: Bool { continuation != nil }
    func pause() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release(_ error: Error? = nil) {
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        continuation = nil
    }
}

final class ConnectionSafetyTests: XCTestCase {
    private func identity(_ generation: Int = 0, token: String = "fixture") -> ConnectionContext {
        ConnectionContext(host: "https://mac.example", token: token, generation: generation)
    }

    func testSummarySaturatesUntrustedCounters() {
        let sessions = [Int.max, Int.max, -1].enumerated().map { index, value in
            Session(id: "\(index)", title: "Fixture", state: "working", workspace: "/fixture",
                    model: "test", permissions: "ask", queued: value, jobs: value)
        }
        let summary = WorkSummary.from(sessions)
        XCTAssertEqual(summary.tasks, Int.max)
        XCTAssertEqual(summary.queued, Int.max)
        XCTAssertEqual(WorkSummary.addingCounter(-10, -20), 0)
    }

    func testResponseLimitRejectsDeclaredAndChunkedOverflowBeforeAppend() throws {
        var response = ResponseAccumulator(limit: 4)
        XCTAssertThrowsError(try response.validate(expectedLength: 5))
        try response.validate(expectedLength: -1)
        for byte in [UInt8(1), 2, 3, 4] { try response.append(byte) }
        XCTAssertThrowsError(try response.append(5))
        XCTAssertEqual(response.data, Data([1, 2, 3, 4]))
        XCTAssertLessThan(BoundedHTTP.limit(operation: "create"), BoundedHTTP.limit(operation: "list"))
        XCTAssertLessThan(BoundedHTTP.limit(operation: "list"), BoundedHTTP.limit(operation: "transcript-sync"))
    }

    func testOversizedSelectedTranscriptRejectedTransactionally() throws {
        let original = Event(id: "1", role: "assistant", tool: "", text: "original")
        var cached = CachedTranscript(revision: "a", events: [original], accessed: Date())
        let huge = Event(id: "2", role: "assistant", tool: "", text: String(repeating: "x", count: CachedTranscript.memoryLimit))
        XCTAssertThrowsError(try cached.reconcile(revision: "b", base: nil, order: nil, changes: [huge], unchanged: false))
        XCTAssertEqual(cached.events, [original])
        XCTAssertEqual(cached.revision, "a")
        XCTAssertTrue(cached.presentations.isEmpty)
    }

    @MainActor func testFailedCandidateLeavesIdentityAndDraftUntouched() async throws {
        let original = identity(), candidate = identity(token: "rejected")
        var current = original
        var draft = "unsent work"
        let gate = ConnectionTestGate()
        let task = Task {
            try await ConnectionCandidateProbe.validate(previous: original, candidate: candidate, current: { current }) { sent in
                XCTAssertEqual(sent, candidate)
                try await gate.pause()
            }
            current = candidate
            draft = ""
        }
        while !(await gate.waiting) { await Task.yield() }
        XCTAssertEqual(current, original)
        XCTAssertEqual(draft, "unsent work")
        await gate.release(URLError(.userAuthenticationRequired))
        do { try await task.value; XCTFail("Rejected probe committed") } catch {}
        XCTAssertEqual(current, original)
        XCTAssertEqual(draft, "unsent work")
    }

    @MainActor func testCandidateCompletionAfterGenerationChangeCannotCommit() async throws {
        let original = identity(), candidate = identity(token: "candidate")
        var current = original
        var committed = false
        let gate = ConnectionTestGate()
        let task = Task {
            try await ConnectionCandidateProbe.validate(previous: original, candidate: candidate, current: { current }) { _ in
                try await gate.pause()
            }
            committed = true
        }
        while !(await gate.waiting) { await Task.yield() }
        current = identity(1)
        await gate.release()
        do { try await task.value; XCTFail("Stale probe committed") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(committed)
    }

    @MainActor func testDelayedActivityCallbackCannotRegisterAfterQuiesceOrCredentialSwitch() async throws {
        let original = identity(), initialEpoch = UUID()
        for switchCredentials in [false, true] {
            var current = original, epoch = initialEpoch
            let lease = ConnectionCallbackLease(context: original, epoch: initialEpoch)
            let gate = ConnectionTestGate()
            var registrations = 0
            let callback = Task {
                try await gate.pause()
                if lease.accepts(current: current, epoch: epoch) { registrations += 1 }
            }
            while !(await gate.waiting) { await Task.yield() }
            if switchCredentials { current = identity(1, token: "replacement") }
            else { epoch = UUID() }
            await gate.release()
            try await callback.value
            XCTAssertEqual(registrations, 0)
        }
    }

    func testCredentialActivationRejectsDelayedOldCacheWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranscriptCache(directory: directory)
        try await cache.activate(key: "old")
        try await cache.save(.init(), key: "old")
        let gate = ConnectionTestGate()
        let writer = Task {
            try await gate.pause()
            try await cache.save(.init(), key: "old")
        }
        while !(await gate.waiting) { await Task.yield() }
        try await cache.activate(key: "new")
        try await cache.save(.init(), key: "new")
        await gate.release()
        do { try await writer.value; XCTFail("Old cache writer succeeded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("old").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new").path))
    }
}
