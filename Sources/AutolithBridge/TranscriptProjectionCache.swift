import Foundation
import BridgeCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Fingerprint every replay segment and live local operation, without reading history.
enum TranscriptSource {
    static func revision(_ source: [String: Any]) throws -> String {
        guard let paths = source["files"] as? [String], let context = source["context"] as? [Any] else {
            throw BridgeError.invalid("Management endpoint did not describe transcript storage.")
        }
        let files = try paths.map { path -> [String] in
            var value = stat()
            guard stat(path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            #if canImport(Darwin)
            let modified = value.st_mtimespec, changed = value.st_ctimespec
            #else
            let modified = value.st_mtim, changed = value.st_ctim
            #endif
            return [path, String(value.st_dev), String(value.st_ino), String(value.st_size),
                    String(modified.tv_sec), String(modified.tv_nsec), String(changed.tv_sec), String(changed.tv_nsec)]
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["files": files, "context": context], options: [.sortedKeys])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Coalesce readers per conversation. Cache only snapshots whose source stayed stable.
final class TranscriptProjectionCache: @unchecked Sendable {
    private final class Entry {
        let slot = DispatchSemaphore(value: 1)
        var source: String?
        var data: Data?
        // The cache lock protects accounting; the slot protects snapshot contents.
        var users = 0
        var bytes = 0
        var accessed = ProcessInfo.processInfo.systemUptime
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func load(sessionID: String, context: BackendRequestContext,
              source: () throws -> String, fetch: () throws -> Data) throws -> Data {
        lock.lock()
        let entry = entries[sessionID] ?? Entry()
        entries[sessionID] = entry; entry.users += 1
        lock.unlock()
        defer {
            lock.lock()
            entry.users -= 1; entry.accessed = ProcessInfo.processInfo.systemUptime
            while entries.count > 12 || entries.values.reduce(0, { $0 + $1.bytes }) > 64 * 1024 * 1024 {
                guard let oldest = entries.filter({ $0.value.users == 0 }).min(by: { $0.value.accessed < $1.value.accessed }) else { break }
                entries[oldest.key] = nil
            }
            lock.unlock()
        }
        while true {
            try context.check()
            if entry.slot.wait(timeout: min(context.deadline, .now() + 0.05)) == .success { break }
        }
        defer { entry.slot.signal() }
        try context.check()
        let before = try source()
        if entry.source == before, let data = entry.data { return data }
        let data = try fetch()
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["error"] == nil, reply["events"] is [[String: Any]] else { return data }
        let after = try source()
        try context.check()
        if before == after && data.count <= 8 * 1024 * 1024 {
            entry.source = after; entry.data = data
        } else {
            entry.source = nil; entry.data = nil
        }
        lock.lock(); entry.bytes = entry.data?.count ?? 0; lock.unlock()
        return data
    }
}
