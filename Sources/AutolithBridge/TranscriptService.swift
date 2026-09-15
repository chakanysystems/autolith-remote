import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Content revisions include edits, removals, ordering, pending sends, and read receipts.
final class TranscriptService: @unchecked Sendable {
    private struct Snapshot { let revision: String; let events: [[String: Any]]; let size: Int; let source: String? }
    private let lock = NSLock()
    private var snapshots: [String: Snapshot] = [:]
    private var order: [String] = []

    func cachedResponse(sessionID: String, source: String, revision: String?) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let cached = snapshots[sessionID], cached.source == source else { return nil }
        if cached.revision == revision { return ["revision": cached.revision, "notModified": true] }
        return ["revision": cached.revision, "events": cached.events, "replaceEvents": true]
    }

    func response(sessionID: String, events: [[String: Any]], revision: String?, source: String? = nil) throws -> [String: Any] {
        let encoded = try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys])
        let current = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        lock.lock(); defer { lock.unlock() }
        let previous = snapshots[sessionID]
        defer {
            snapshots[sessionID] = Snapshot(revision: current, events: events, size: encoded.count, source: source)
            order.removeAll { $0 == sessionID }; order.append(sessionID)
            while order.count > 20 || snapshots.values.reduce(0, { $0 + $1.size }) > 64 * 1024 * 1024 {
                snapshots.removeValue(forKey: order.removeFirst())
            }
        }
        if revision == current { return ["revision": current, "notModified": true] }
        guard let revision, let previous, previous.revision == revision else {
            return ["revision": current, "events": events, "replaceEvents": true]
        }
        var old: [String: NSDictionary] = [:]
        for event in previous.events { if let id = event["id"] as? String { old[id] = event as NSDictionary } }
        let changed = events.filter { event in
            guard let id = event["id"] as? String else { return true }
            return old[id] != event as NSDictionary
        }
        return ["revision": current, "baseRevision": revision, "eventOrder": events.compactMap { $0["id"] as? String }, "events": changed]
    }
}
