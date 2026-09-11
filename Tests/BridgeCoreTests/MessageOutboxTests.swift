import XCTest
@testable import BridgeCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class MessageOutboxTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("outbox.json"))
    }

    func testQueuedMessagesCanBeEditedAndUnsentWithoutDispatch() throws {
        try fixture { file in
            let store = try MessageOutbox(file: file), id = UUID().uuidString
            _ = try store.enqueue(id: id, sessionID: "session", workspace: "/work", text: "first", now: 100)
            XCTAssertNil(try store.claim(now: 114))
            XCTAssertEqual(try store.edit(id, text: "second", now: 110).text, "second")
            try store.unsend(id, now: 111)
            XCTAssertNil(try store.claim(now: 200))
            XCTAssertEqual(store.message(id)?.state, "unsent")
        }
    }

    func testDispatchBoundaryClosesEditingAndPreventsSecondClaim() throws {
        try fixture { file in
            let store = try MessageOutbox(file: file), id = UUID().uuidString
            _ = try store.enqueue(id: id, sessionID: "session", workspace: "/work", text: "question", now: 100)
            XCTAssertEqual(try store.claim(now: 115)?.id, id)
            XCTAssertThrowsError(try store.edit(id, text: "changed", now: 116))
            XCTAssertThrowsError(try store.unsend(id, now: 116))
            XCTAssertNil(try store.claim(now: 116))
            try store.finish(id, delivered: true)
            XCTAssertEqual(store.message(id)?.state, "sent")
        }
    }

    func testCrashLeavesHandoffUncertainAndKeepsPendingWork() throws {
        try fixture { file in
            var store: MessageOutbox? = try MessageOutbox(file: file)
            let first = UUID().uuidString, second = UUID().uuidString
            _ = try store!.enqueue(id: first, sessionID: "session", workspace: "/work", text: "first", now: 100)
            _ = try store!.enqueue(id: second, sessionID: "session", workspace: "/work", text: "second", now: 200)
            _ = try store!.claim(now: 115)
            try store!.setRead("session#1", value: false)
            XCTAssertThrowsError(try MessageOutbox(file: file))
            store = nil
            let restored = try MessageOutbox(file: file)
            XCTAssertEqual(restored.message(first)?.state, "uncertain")
            XCTAssertEqual(try restored.claim(now: 300)?.id, second)
            XCTAssertFalse(restored.isRead("session#1", role: "user"))
        }
    }

    func testRequestIdentityIsIdempotentAndScheduleIsPreserved() throws {
        try fixture { file in
            let store = try MessageOutbox(file: file), id = UUID().uuidString
            let first = try store.enqueue(id: id, sessionID: "session", workspace: "/work", text: "question", now: 100, scheduled: 500)
            let second = try store.enqueue(id: id, sessionID: "session", workspace: "/work", text: "question", now: 101)
            XCTAssertEqual(first, second)
            XCTAssertThrowsError(try store.enqueue(id: id, sessionID: "other", workspace: "/work", text: "question", now: 102))
            XCTAssertNil(try store.claim(now: 499))
            XCTAssertEqual(try store.claim(now: 500)?.id, id)
        }
    }

    func testReadDefaultsAndExplicitOverridesSurviveRestart() throws {
        try fixture { file in
            var store: MessageOutbox? = try MessageOutbox(file: file)
            XCTAssertFalse(store!.isRead("session#answer", role: "assistant"))
            XCTAssertTrue(store!.isRead("session#question", role: "user"))
            try store!.setRead("session#answer", value: true)
            try store!.setRead("session#question", value: false)
            XCTAssertTrue(store!.isRead("session#answer", role: "assistant"))
            XCTAssertFalse(store!.isRead("session#question", role: "user"))
            store = nil
            let restored = try MessageOutbox(file: file)
            XCTAssertTrue(restored.isRead("session#answer", role: "assistant"))
            XCTAssertFalse(restored.isRead("session#question", role: "user"))
            XCTAssertFalse(restored.isRead("other#answer", role: "assistant"))
            XCTAssertTrue(restored.isRead("other#question", role: "user"))
            try restored.setRead("session#answer", value: false)
            XCTAssertFalse(restored.isRead("session#answer", role: "assistant"))
        }
    }

    // This is also the legacy disk schema: no completedAt or retiredIDs is required.
    private struct Seed: Encodable {
        var messages: [String: MessageOutbox.Message]
        var read: [String: Bool]
    }

    private func seed(_ messages: [MessageOutbox.Message], read: [String: Bool] = [:], file: URL) throws {
        try DurableJSONFile.prepareDirectory(file.deletingLastPathComponent())
        let value = Seed(messages: Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) }), read: read)
        try DurableJSONFile.write(JSONEncoder().encode(value), to: file)
    }

    private func record(state: String, created: Double = 100, completedAt: Double? = nil,
                        dispatchAt: Double = 115) -> MessageOutbox.Message {
        MessageOutbox.Message(id: UUID().uuidString, sessionID: "session", workspace: "/work", text: "question",
                              created: created, dispatchAt: dispatchAt, state: state, completedAt: completedAt)
    }

    private func storedCounts(_ file: URL) throws -> (messages: Int, retired: Int) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return (try XCTUnwrap(object["messages"] as? [String: Any]).count,
                try XCTUnwrap(object["retiredIDs"] as? [String]).count)
    }

    func testLegacyTerminalOverflowRetiresPayloadsNotPendingWork() throws {
        try fixture { file in
            let terminal = (0..<10_010).map { index in
                record(state: index.isMultiple(of: 2) ? "sent" : "unsent", created: Double(index))
            }
            let queued = record(state: "queued")
            let scheduled = record(state: "queued", dispatchAt: 1_000_000)
            let dispatching = record(state: "dispatching")
            let uncertain = record(state: "uncertain")
            let unknown = record(state: "future-state")
            let work = [queued, scheduled, dispatching, uncertain, unknown]
            let retired = terminal[0], retained = terminal.last!
            try seed(terminal + work,
                     read: ["session#outbox-" + retired.id: false, "session#answer": true], file: file)
            var store: MessageOutbox? = try MessageOutbox(file: file, now: 20_000)
            XCTAssertEqual(try storedCounts(file).messages, MessageOutbox.terminalLimit + work.count)
            XCTAssertEqual(try storedCounts(file).retired, terminal.count - MessageOutbox.terminalLimit)
            XCTAssertNil(store!.message(retired.id))
            XCTAssertEqual(store!.message(retained.id), retained)
            XCTAssertEqual(store!.message(queued.id), queued)
            XCTAssertEqual(store!.message(scheduled.id), scheduled)
            XCTAssertEqual(store!.message(dispatching.id)?.state, "uncertain")
            XCTAssertEqual(store!.message(uncertain.id), uncertain)
            XCTAssertEqual(store!.message(unknown.id), unknown)
            XCTAssertTrue(store!.isRead("session#outbox-" + retired.id, role: "user"))
            XCTAssertTrue(store!.isRead("session#answer", role: "assistant"))
            XCTAssertThrowsError(try store!.enqueue(id: retired.id, sessionID: "session", workspace: "/work", text: "question", now: 20_000))
            XCTAssertEqual(try store!.enqueue(id: retained.id, sessionID: "session", workspace: "/work", text: "question", now: 20_000), retained)
            let fresh = try store!.enqueue(id: UUID().uuidString, sessionID: "session", workspace: "/work", text: "new", now: 20_000)
            store = nil
            // Even long after payload expiry, UUIDs cannot become new dispatches.
            let restored = try MessageOutbox(file: file, now: 10 * MessageOutbox.terminalLifetime)
            XCTAssertEqual(try storedCounts(file).messages, work.count + 1)
            XCTAssertEqual(try storedCounts(file).retired, terminal.count)
            XCTAssertThrowsError(try restored.enqueue(id: retired.id.lowercased(), sessionID: "session", workspace: "/work", text: "question"))
            XCTAssertThrowsError(try restored.enqueue(id: retained.id, sessionID: "session", workspace: "/work", text: "changed"))
            XCTAssertEqual(restored.message(fresh.id), fresh)
            XCTAssertEqual(try restored.claim(now: 20_000)?.id, queued.id)
            XCTAssertEqual(try restored.claim(now: 20_020)?.id, fresh.id)
            XCTAssertNil(try restored.claim(now: 20_020))
            XCTAssertEqual(restored.message(scheduled.id), scheduled)
            XCTAssertEqual(restored.message(dispatching.id)?.state, "uncertain")
            XCTAssertEqual(restored.message(uncertain.id)?.state, "uncertain")
            XCTAssertEqual(restored.message(unknown.id), unknown)
        }
    }

    func testOnlyUnresolvedWorkConsumesCapacity() throws {
        try fixture { file in
            let pending = (0..<MessageOutbox.pendingLimit).map { _ in record(state: "queued", dispatchAt: 100_000) }
            let completed = record(state: "sent")
            try seed(pending + [completed], file: file)
            let store = try MessageOutbox(file: file, now: 200)
            XCTAssertThrowsError(try store.enqueue(id: UUID().uuidString, sessionID: "session", workspace: "/work", text: "new", now: 200))
            XCTAssertEqual(store.pending(sessionID: "session").count, MessageOutbox.pendingLimit)
            // A full queue still accepts a retry of existing work without adding a slot.
            XCTAssertEqual(try store.enqueue(id: pending[0].id, sessionID: "session", workspace: "/work", text: "question", now: 200), pending[0])
            try store.unsend(pending[0].id, now: 200)
            _ = try store.enqueue(id: UUID().uuidString, sessionID: "session", workspace: "/work", text: "new", now: 201)
            XCTAssertEqual(store.pending(sessionID: "session").count, MessageOutbox.pendingLimit)
            XCTAssertEqual(store.message(pending[0].id)?.state, "unsent")
            XCTAssertEqual(store.message(completed.id), completed)
        }
    }

    func testUncertainAndUnknownStatesAlsoConsumeCapacity() throws {
        try fixture { file in
            let work = (0..<MessageOutbox.pendingLimit).map { index in
                record(state: index.isMultiple(of: 2) ? "uncertain" : "future-state")
            }
            try seed(work, file: file)
            let store = try MessageOutbox(file: file, now: 200)
            XCTAssertThrowsError(try store.enqueue(id: UUID().uuidString, sessionID: "session", workspace: "/work", text: "new", now: 200))
            XCTAssertEqual(try storedCounts(file).messages, work.count)
            XCTAssertNil(try store.claim(now: 1_000_000_000))
            XCTAssertEqual(try storedCounts(file).messages, work.count)
        }
    }

    func testTerminalAgeStartsAtCompletionAndRetiredIDsNeverReplay() throws {
        try fixture { file in
            var store: MessageOutbox? = try MessageOutbox(file: file, now: 100)
            let sentID = UUID().uuidString, unsentID = UUID().uuidString
            _ = try store!.enqueue(id: sentID, sessionID: "session", workspace: "/work", text: "sent", now: 100)
            _ = try store!.claim(now: 115)
            let completed = 2 * MessageOutbox.terminalLifetime
            try store!.finish(sentID, delivered: true, now: completed)
            _ = try store!.enqueue(id: unsentID, sessionID: "session", workspace: "/work", text: "unsent", now: completed)
            try store!.unsend(unsentID, now: completed)
            XCTAssertEqual(store!.message(sentID)?.state, "sent")
            XCTAssertEqual(store!.message(unsentID)?.state, "unsent")
            XCTAssertNil(try store!.claim(now: completed + MessageOutbox.terminalLifetime - 1))
            XCTAssertNotNil(store!.message(sentID))
            XCTAssertNotNil(store!.message(unsentID))
            XCTAssertNil(try store!.claim(now: completed + MessageOutbox.terminalLifetime))
            XCTAssertNil(store!.message(sentID))
            XCTAssertNil(store!.message(unsentID))
            XCTAssertEqual(try storedCounts(file).retired, 2)
            store = nil
            let restored = try MessageOutbox(file: file, now: completed + MessageOutbox.terminalLifetime)
            // A backwards clock also cannot revive a retired ID.
            XCTAssertThrowsError(try restored.enqueue(id: sentID, sessionID: "session", workspace: "/work", text: "sent", now: 100))
            XCTAssertThrowsError(try restored.enqueue(id: unsentID, sessionID: "session", workspace: "/work", text: "unsent", now: 100))
            XCTAssertNil(try restored.claim(now: completed * 100))
        }
    }

    func testCompletionPrunesCountWithoutRestartAndPreservesRetryIdentity() throws {
        try fixture { file in
            let terminal = (0..<MessageOutbox.terminalLimit).map { index in record(state: "sent", created: Double(index)) }
            try seed(terminal, file: file)
            let store = try MessageOutbox(file: file, now: 2_000)
            let id = UUID().uuidString
            _ = try store.enqueue(id: id, sessionID: "session", workspace: "/work", text: "new", now: 2_000, scheduled: 3_000)
            XCTAssertEqual(try store.enqueue(id: id.lowercased(), sessionID: "session", workspace: "/work", text: "new", now: 2_001).id, id)
            XCTAssertThrowsError(try store.enqueue(id: id, sessionID: "session", workspace: "/other", text: "new", now: 2_001))
            XCTAssertEqual(try store.claim(now: 3_000)?.id, id)
            try store.finish(id, delivered: true, now: 3_001)
            XCTAssertNil(store.message(terminal[0].id))
            XCTAssertEqual(try storedCounts(file).messages, MessageOutbox.terminalLimit)
            XCTAssertEqual(try storedCounts(file).retired, 1)
            // Retrying after the scheduled date returns the receipt, not a schedule error or a new claim.
            XCTAssertEqual(try store.enqueue(id: id, sessionID: "session", workspace: "/work", text: "new", now: 3_002, scheduled: 3_000).state, "sent")
            XCTAssertNil(try store.claim(now: 4_000))
        }
    }
    func testOutboxReceiptRequiresAnExistingMessageInThatSession() throws {
        try fixture { file in
            let store = try MessageOutbox(file: file, now: 100), id = UUID().uuidString
            _ = try store.enqueue(id: id, sessionID: "session", workspace: "/work", text: "question", now: 100)
            XCTAssertThrowsError(try store.setMessageRead(id, sessionID: "other", value: false))
            try store.setMessageRead(id, sessionID: "session", value: false)
            XCTAssertFalse(store.isRead("session#outbox-" + id, role: "user"))
            try store.unsend(id, now: 101)
            XCTAssertThrowsError(try store.setMessageRead(id, sessionID: "session", value: true))
            _ = try store.claim(now: 101 + MessageOutbox.terminalLifetime)
            XCTAssertThrowsError(try store.setMessageRead(id, sessionID: "session", value: false))
        }
    }
    func testPreparationRecoveryBackoffAndExplicitAbandonment() throws {
        try fixture { file in
            var store: MessageOutbox? = try MessageOutbox(file: file, now: 100)
            let id = UUID().uuidString
            _ = try store!.enqueue(id: id, sessionID: "s", workspace: "/w", text: "q", now: 100)
            _ = try store!.claim(now: 115, preparing: true)
            store = nil
            store = try MessageOutbox(file: file, now: 200)
            XCTAssertEqual(store!.message(id)?.state, "queued")
            XCTAssertNil(try store!.claim(now: 229, preparing: true))
            var time = 230.0
            XCTAssertEqual(store!.message(id)?.attempts, 1)
            for attempt in 2...5 {
                XCTAssertEqual(try store!.claim(now: time, preparing: true)?.id, id)
                try store!.preparationFailed(id, now: time)
                XCTAssertEqual(store!.message(id)?.attempts, attempt)
                XCTAssertNil(try store!.claim(now: time + 1, preparing: true))
                time = store!.message(id)!.dispatchAt
            }
            XCTAssertEqual(store!.message(id)?.state, "failed")
            XCTAssertNil(try store!.claim(now: time + 10000, preparing: true))
            _ = try store!.retry(id, now: time)
            _ = try store!.claim(now: time + 30, preparing: true)
            XCTAssertThrowsError(try store!.abandon(id))
            try store!.beginHandoff(id)
            try store!.finish(id, delivered: false, now: time + 30)
            XCTAssertThrowsError(try store!.retry(id))
            try store!.abandon(id)
            try store!.abandon(id)
            store = nil
            let restored = try MessageOutbox(file: file, now: time + 31)
            XCTAssertEqual(restored.receipt(id), "retired")
            XCTAssertNil(restored.message(id))
            XCTAssertThrowsError(try restored.enqueue(id: id.lowercased(), sessionID: "s", workspace: "/w", text: "q"))
        }
    }

    func testPersistenceFailureOnEitherSideOfRenameKeepsMemoryConsistent() throws {
        for stage in [DurableJSONFile.Stage.temporaryCreated, .written, .fileSynced, .renamed, .directorySynced] {
            try fixture { file in
                var store: MessageOutbox? = try MessageOutbox(file: file, now: 100)
                let id = UUID().uuidString
                store!.persist = { data, url in
                    try DurableJSONFile.write(data, to: url) { current in
                        if current == stage { throw BridgeError.invalid("Injected failure") }
                    }
                }
                XCTAssertThrowsError(try store!.enqueue(id: id, sessionID: "s", workspace: "/w", text: "q", now: 100))
                let visible = store!.message(id)
                XCTAssertEqual(visible != nil, stage == .renamed || stage == .directorySynced)
                store = nil
                let restored = try MessageOutbox(file: file, now: 100)
                XCTAssertEqual(restored.message(id), visible)
                let files = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
                XCTAssertEqual(Set(files), ["outbox.json", "outbox.json.lock"])
            }
        }
    }

    func testAggregateBudgetBackpressureLeavesTransitionHeadroom() throws {
        try fixture { file in
            let records = (0..<251).map { _ -> MessageOutbox.Message in
                var value = record(state: "queued")
                value.text = String(repeating: "x", count: 100_000)
                return value
            }
            try seed(records, file: file)
            let store = try MessageOutbox(file: file, now: 100)
            XCTAssertThrowsError(try store.enqueue(id: UUID().uuidString, sessionID: "s", workspace: "/w", text: String(repeating: "y", count: 100_000), now: 100))
            let message = try XCTUnwrap(store.claim(now: 115, preparing: true))
            try store.beginHandoff(message.id)
            try store.finish(message.id, delivered: false, now: 116)
            try store.abandon(message.id)
            XCTAssertEqual(store.receipt(message.id), "retired")
            XCTAssertLessThan(try Data(contentsOf: file).count, MessageOutbox.byteLimit)
            XCTAssertThrowsError(try store.setRead(String(repeating: "k", count: 8193), value: true))
            XCTAssertThrowsError(try store.enqueue(id: UUID().uuidString, sessionID: String(repeating: "s", count: 4097), workspace: "/w", text: "q"))
        }
    }

    func testRejectsUnsafeStateDirectoryFileAndLock() throws {
        try fixture { file in
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            XCTAssertThrowsError(try MessageOutbox(file: file))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let target = directory.appendingPathComponent("target")
            try Data("{}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            XCTAssertThrowsError(try MessageOutbox(file: file))
            try FileManager.default.removeItem(at: file)
            let lock = URL(fileURLWithPath: file.path + ".lock")
            try? FileManager.default.removeItem(at: lock)
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
            XCTAssertThrowsError(try MessageOutbox(file: file))
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "{}")
        }
    }
    func testTemporaryPermissionsPrecedePayloadAndReplacement() throws {
        try fixture { file in
            let payload = Data("private-payload".utf8)
            try DurableJSONFile.write(payload, to: file) { stage in
                if stage == .temporaryCreated {
                    let temporary = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil).first)
                    let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
                    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                    XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 0)
                }
            }
            XCTAssertEqual(try DurableJSONFile.read(at: file, maximumBytes: payload.count), payload)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertThrowsError(try DurableJSONFile.read(at: file, maximumBytes: payload.count - 1))
        }
    }
    func testLifetimeLedgerBackpressureNeverEvictsReplayIdentities() throws {
        try fixture { file in
            var store: MessageOutbox? = try MessageOutbox(file: file, now: 100)
            store!.admissionByteBudget = 1200
            var retired: [String] = []
            var rejected = false
            for _ in 0..<100 {
                let id = UUID().uuidString
                do { _ = try store!.enqueue(id: id, sessionID: "s", workspace: "/w", text: "q", now: 100) }
                catch { rejected = true; break }
                try store!.abandon(id)
                retired.append(id)
            }
            XCTAssertTrue(rejected)
            XCTAssertFalse(retired.isEmpty)
            XCTAssertTrue(store!.pending(sessionID: "s").isEmpty)
            store = nil
            let restored = try MessageOutbox(file: file, now: 100)
            restored.admissionByteBudget = 1200
            for id in retired {
                XCTAssertEqual(restored.receipt(id.lowercased()), "retired")
                XCTAssertThrowsError(try restored.enqueue(id: id, sessionID: "s", workspace: "/w", text: "q", now: 100))
            }
            XCTAssertThrowsError(try restored.enqueue(id: UUID().uuidString, sessionID: "s", workspace: "/w", text: "q", now: 100))
        }
    }

    func testReadMetadataCountBoundAllowsExistingOverrideChanges() throws {
        try fixture { file in
            let read = Dictionary(uniqueKeysWithValues: (0..<MessageOutbox.readLimit).map { ("s#\($0)", true) })
            try seed([], read: read, file: file)
            let store = try MessageOutbox(file: file, now: 100)
            try store.setRead("s#0", value: false)
            XCTAssertFalse(store.isRead("s#0", role: "user"))
            XCTAssertThrowsError(try store.setRead("s#new", value: true))
            XCTAssertFalse(store.isRead("s#new", role: "assistant"))
        }
    }
    func testRestrictiveUmaskDoesNotProduceUnreadableStateOrLock() throws {
        try fixture { file in
            try DurableJSONFile.prepareDirectory(file.deletingLastPathComponent())
            let previous = umask(0o777)
            defer { umask(previous) }
            let lock = try DurableJSONFile.openLock(at: URL(fileURLWithPath: file.path + ".lock"))
            defer { close(lock) }
            try DurableJSONFile.write(Data("private".utf8), to: file)
            XCTAssertEqual(try DurableJSONFile.read(at: file, maximumBytes: 10), Data("private".utf8))
            for path in [file.path, file.path + ".lock"] {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
        }
    }

    func testExistingUnsafeLockIsRejectedWithoutChangingPermissions() throws {
        try fixture { file in
            let lock = URL(fileURLWithPath: file.path + ".lock")
            try DurableJSONFile.prepareDirectory(file.deletingLastPathComponent())
            try Data().write(to: lock)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
            XCTAssertThrowsError(try DurableJSONFile.openLock(at: lock))
            let attributes = try FileManager.default.attributesOfItem(atPath: lock.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        }
    }
    func testDirectorySynchronizationRetriesExistingAncestorEntriesAfterFailure() throws {
        try fixture { file in
            let directory = file.deletingLastPathComponent().appendingPathComponent("nested/state")
            var first: [String] = []
            XCTAssertThrowsError(try DurableJSONFile.prepareDirectory(directory) { descriptor in
                var attributes = stat()
                XCTAssertEqual(fstat(descriptor, &attributes), 0)
                first.append("\(attributes.st_dev):\(attributes.st_ino)")
                if first.count == 2 { throw BridgeError.invalid("Injected parent synchronization failure") }
                XCTAssertEqual(fsync(descriptor), 0)
            })
            XCTAssertEqual(first.count, 2)
            var retried: [String] = []
            try DurableJSONFile.prepareDirectory(directory) { descriptor in
                var attributes = stat()
                XCTAssertEqual(fstat(descriptor, &attributes), 0)
                retried.append("\(attributes.st_dev):\(attributes.st_ino)")
                XCTAssertEqual(fsync(descriptor), 0)
            }
            XCTAssertEqual(Array(retried.prefix(first.count)), first)
            XCTAssertGreaterThan(retried.count, first.count)
        }
    }

    func testExistingReadOverridesUseTransitionReserveWhileNewMetadataIsRejected() throws {
        try fixture { file in
            let store = try MessageOutbox(file: file, now: 100)
            let id = UUID().uuidString, second = UUID().uuidString
            _ = try store.enqueue(id: id, sessionID: "s", workspace: "/w", text: "q", now: 100)
            _ = try store.enqueue(id: second, sessionID: "s", workspace: "/w", text: "q", now: 100)
            try store.setRead("s#1", value: true)
            try store.setMessageRead(id, sessionID: "s", value: true)
            store.admissionByteBudget = 1
            try store.setRead("s#1", value: false)
            try store.setMessageRead(id, sessionID: "s", value: false)
            XCTAssertFalse(store.isRead("s#1", role: "user"))
            XCTAssertFalse(store.isRead("s#outbox-" + id, role: "user"))
            XCTAssertThrowsError(try store.setRead("s#2", value: true))
            XCTAssertThrowsError(try store.setMessageRead(second, sessionID: "s", value: false))
            XCTAssertTrue(store.isRead("s#outbox-" + second, role: "user"))
        }
    }
}
