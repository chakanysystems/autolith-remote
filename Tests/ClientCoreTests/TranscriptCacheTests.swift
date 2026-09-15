import XCTest
@testable import ClientCore

final class TranscriptCacheTests: XCTestCase {
    func testResponseDividersFollowActivityAndTrackHistoryEdits() throws {
        for role in ["tool-call", "tool-result", "thinking", "user", "assistant"] {
            let preceding = Event(id: "before", role: role, tool: "", text: "Work")
            let answer = event("answer", "Response")
            let continuation = event("continued", "More response")
            var cache = CachedTranscript(revision: "", events: [], accessed: Date())
            try cache.reconcile(revision: "a", base: nil, order: nil,
                                changes: [preceding, answer, continuation], unchanged: false)
            XCTAssertEqual(cache.presentations["answer"]?.startsResponse, preceding.activityKind != nil)
            XCTAssertEqual(cache.presentations["before"]?.startsResponse, false)
            XCTAssertEqual(cache.presentations["continued"]?.startsResponse, false)
            try cache.reconcile(revision: "b", base: "a", order: ["answer", "before", "continued"], changes: [], unchanged: false)
            XCTAssertEqual(cache.presentations["answer"]?.startsResponse, false)
            XCTAssertEqual(cache.presentations["continued"]?.startsResponse, preceding.activityKind != nil)
            try cache.reconcile(revision: "c", base: "b", order: ["answer", "continued"], changes: [], unchanged: false)
            XCTAssertEqual(cache.presentations["continued"]?.startsResponse, false)
        }
    }

    private func event(_ id: String, _ text: String) -> Event {
        Event(id: id, role: "assistant", tool: "", text: text)
    }

    func testRewritesDeletesReorderingAndTruncationReplaceHistory() throws {
        var cache = CachedTranscript(revision: "a", events: [event("1", "old"), event("2", "deleted"), event("3", "third")], accessed: .distantPast)
        try cache.reconcile(revision: "b", base: "a", order: ["3", "1"], changes: [event("1", "rewritten")], unchanged: false)
        XCTAssertEqual(cache.events, [event("3", "third"), event("1", "rewritten")])
        try cache.reconcile(revision: "c", base: "b", order: [], changes: [], unchanged: false)
        XCTAssertTrue(cache.events.isEmpty)
        try cache.reconcile(revision: "d", base: nil, order: nil, changes: [event("1", "new history")], unchanged: false)
        XCTAssertEqual(cache.events, [event("1", "new history")])
    }

    func testInvalidDeltasNeverPartiallyChangeCache() throws {
        let initial = [event("1", "original")]
        for (base, order, changes) in [
            ("wrong", ["1"], [event("1", "edit")]),
            ("a", ["missing"], []),
            ("a", ["1", "1"], []),
            ("a", ["1"], [event("1", "first"), event("1", "second")]),
            ("a", ["1"], [event("other", "extra")])
        ] {
            var cache = CachedTranscript(revision: "a", events: initial, accessed: .distantPast)
            XCTAssertThrowsError(try cache.reconcile(revision: "b", base: base, order: order, changes: changes, unchanged: false))
            XCTAssertEqual(cache.events, initial)
            XCTAssertEqual(cache.revision, "a")
        }
        var cache = CachedTranscript(revision: "a", events: initial, accessed: .distantPast)
        XCTAssertThrowsError(try cache.reconcile(revision: "b", base: nil, order: nil, changes: nil, unchanged: true))
        try cache.reconcile(revision: "a", base: nil, order: nil, changes: nil, unchanged: true)
        XCTAssertEqual(cache.events, initial)
    }

    func testDiskRestartDeletionCredentialsAndCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranscriptCache(directory: directory)
        let key = TranscriptCache.key(host: "https://computer.example", token: "secret")
        let other = TranscriptCache.key(host: "https://computer.example", token: "changed")
        XCTAssertNotEqual(key, other)
        let session = Session(id: "s", title: "Fixture", state: "idle", workspace: "/fixture", model: "test", permissions: "ask", queued: 0, jobs: 0, updatedAt: nil)
        let transcript = CachedTranscript(revision: "a", events: [event("1", "hello")], accessed: Date())
        try await cache.save(.init(sessions: [session], transcripts: ["s": transcript]), key: key)
        let restarted = TranscriptCache(directory: directory)
        let restored = await restarted.load(key: key)
        XCTAssertEqual(restored.transcripts["s"]?.events, transcript.events)
        let isolated = await restarted.load(key: other)
        XCTAssertTrue(isolated.sessions.isEmpty)
        try await cache.save(.init(sessions: [], transcripts: ["s": transcript]), key: key)
        let deleted = await restarted.load(key: key)
        XCTAssertTrue(deleted.transcripts.isEmpty)
        try Data("partial JSON".utf8).write(to: directory.appendingPathComponent(key))
        let corrupt = await restarted.load(key: key)
        XCTAssertTrue(corrupt.sessions.isEmpty)
    }

    func testDiskCacheEvictsLeastRecentlyUsed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranscriptCache(directory: directory)
        let sessions = (0..<15).map { Session(id: String($0), title: "Fixture", state: "idle", workspace: "/fixture", model: "test", permissions: "ask", queued: 0, jobs: 0, updatedAt: nil) }
        let transcripts = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { index, session in
            (session.id, CachedTranscript(revision: "a", events: [event("1", "hello")], accessed: Date(timeIntervalSince1970: Double(index))))
        })
        try await cache.save(.init(sessions: sessions, transcripts: transcripts), key: "fixture")
        let restored = await cache.load(key: "fixture")
        XCTAssertEqual(restored.transcripts.count, 12)
        XCTAssertNil(restored.transcripts["0"])
        XCTAssertNotNil(restored.transcripts["14"])
    }

    func testOversizedReplacementCannotLeaveDeletedHistoryOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranscriptCache(directory: directory, byteLimit: 1024)
        let session = Session(id: "s", title: "Fixture", state: "idle", workspace: "/fixture", model: "test", permissions: "ask", queued: 0, jobs: 0, updatedAt: nil)
        try await cache.save(.init(sessions: [session], transcripts: ["s": .init(revision: "a", events: [event("deleted", "small")], accessed: Date())]), key: "fixture")
        try await cache.save(.init(sessions: [session], transcripts: ["s": .init(revision: "b", events: [event("new", String(repeating: "x", count: 4096))], accessed: Date())]), key: "fixture")
        let restored = await cache.load(key: "fixture")
        XCTAssertNil(restored.transcripts["s"])
        XCTAssertEqual(restored.sessions.map(\.id), ["s"])
    }
}
