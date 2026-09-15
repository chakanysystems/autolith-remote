import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

struct CachedTranscript: Codable, Sendable {
    var revision: String
    var events: [Event]
    var accessed: Date
    var byteCost: Int? = nil
    var presentations: [String: EventPresentation] = [:]
    var shareText: String = ""
    private enum CodingKeys: String, CodingKey { case revision, events, accessed, byteCost }
    static let memoryLimit = 16 * 1024 * 1024
    static let eventLimit = 10_000

    static func validate(_ events: [Event]) throws {
        guard events.count <= eventLimit else { throw CacheError.tooLarge }
        var cost = 0
        for event in events {
            cost = WorkSummary.addingCounter(cost, event.text.utf8.count)
            cost = WorkSummary.addingCounter(cost, event.id.utf8.count + event.tool.utf8.count + 512)
            guard cost <= memoryLimit / 4 else { throw CacheError.tooLarge }
        }
    }

    mutating func reconcile(revision: String, base: String?, order: [String]?, changes: [Event]?, unchanged: Bool) throws {
        let previous = events
        if unchanged {
            guard self.revision == revision else { throw CacheError.invalidRevision }
        } else if let order {
            guard base == self.revision, let changes,
                  Set(order).count == order.count,
                  Set(changes.map(\.id)).count == changes.count,
                  Set(changes.map(\.id)).isSubset(of: Set(order)) else { throw CacheError.invalidRevision }
            var byID: [String: Event] = [:]
            for event in events { byID[event.id] = event }
            for event in changes { byID[event.id] = event }
            let replacement = order.compactMap { byID[$0] }
            guard replacement.count == order.count else { throw CacheError.invalidRevision }
            events = replacement
        } else {
            guard let changes, Set(changes.map(\.id)).count == changes.count else { throw CacheError.invalidRevision }
            events = changes
        }
        do { try Self.validate(events) }
        catch { events = previous; throw error }
        self.revision = revision; accessed = Date()
        if !unchanged || presentations.isEmpty { preparePresentation(previous: previous) }
        if !unchanged || byteCost == nil { measureSize() }
    }
    mutating func measureSize() {
        byteCost = events.reduce(0) { $0 + $1.text.utf8.count * 2 + $1.id.utf8.count + $1.tool.utf8.count + 512 } + shareText.utf8.count
    }
    mutating func preparePresentation(previous: [Event] = []) {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var rendered: [String: EventPresentation] = [:]
        for (index, event) in events.enumerated() {
            if let existing = old[event.id], existing.text == event.text, existing.role == event.role,
               existing.tool == event.tool, let presentation = presentations[event.id] {
                rendered[event.id] = presentation
            } else { rendered[event.id] = EventPresentation(event) }
            rendered[event.id]?.startsResponse = event.role == "assistant" && event.activityKind == nil
                && index > 0 && events[index - 1].activityKind != nil
        }
        presentations = rendered
        shareText = events.map { "\($0.role):\n\($0.text)" }.joined(separator: "\n\n")
    }
    enum CacheError: Error { case invalidRevision, tooLarge }
}

/// One protected cache per authenticated endpoint. Snapshot replacement is atomic.
actor TranscriptCache {
    struct Snapshot: Codable, Sendable {
        var version = 1
        var sessions: [Session] = []
        var transcripts: [String: CachedTranscript] = [:]
    }
    static let shared = TranscriptCache()
    private let directory: URL
    private let byteLimit: Int
    private var activeKey: String?

    /// Serialize credential activation and deletion with saves. Late old saves are rejected.
    func activate(key: String, initializing: Bool = false) throws {
        guard !initializing || activeKey == nil else { return }
        activeKey = key
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != key {
            try FileManager.default.removeItem(at: old)
        }
    }
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AutolithTranscripts"), byteLimit: Int = 64 * 1024 * 1024) {
        self.directory = directory
        self.byteLimit = max(1, byteLimit)
    }
    static func key(host: String, token: String) -> String {
        SHA256.hash(data: Data((host + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func load(key: String) -> Snapshot {
        let url = directory.appendingPathComponent(key)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= byteLimit,
              let data = try? Data(contentsOf: url), data.count <= byteLimit,
              var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 else { return Snapshot() }
        for id in snapshot.transcripts.keys {
            guard let transcript = snapshot.transcripts[id], (try? CachedTranscript.validate(transcript.events)) != nil else {
                snapshot.transcripts[id] = nil
                continue
            }
            snapshot.transcripts[id]?.preparePresentation()
            snapshot.transcripts[id]?.measureSize()
        }
        return snapshot
    }
    func save(_ snapshot: Snapshot, key: String) throws {
        guard activeKey == nil || activeKey == key else { throw CancellationError() }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(key)
        var bounded = snapshot
        let valid = Set(snapshot.sessions.map(\.id))
        bounded.transcripts = bounded.transcripts.filter { valid.contains($0.key) }
        var oldest = bounded.transcripts.keys.sorted { bounded.transcripts[$0]!.accessed < bounded.transcripts[$1]!.accessed }
        var data = try JSONEncoder().encode(bounded)
        while (data.count > byteLimit || bounded.transcripts.count > 12), !oldest.isEmpty {
            bounded.transcripts.removeValue(forKey: oldest.removeFirst())
            data = try JSONEncoder().encode(bounded)
        }
        // Even an oversized session manifest replaces the old cache, preserving deletions.
        if data.count > byteLimit { data = try JSONEncoder().encode(Snapshot()) }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var resource = url; try resource.setResourceValues(values)
        data.removeAll()
    }
}
