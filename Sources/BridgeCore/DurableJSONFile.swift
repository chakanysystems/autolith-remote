import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Private, descriptor-based storage. A rename is the visibility commit point.
public enum DurableJSONFile {
    /// The replacement is visible, but its crash durability could not be confirmed.
    /// Keep the replacement in memory; rolling it back would disagree with disk.
    public struct CommitError: Error { public let underlying: Error }
    enum Stage: Equatable { case temporaryCreated, written, fileSynced, renamed, directorySynced }

    private static func failure(_ operation: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: operation])
    }

    public static func prepareDirectory(_ directory: URL) throws {
        try prepareDirectory(directory) { descriptor in
            guard fsync(descriptor) == 0 else { throw failure("Synchronize state directory ancestor") }
        }
    }

    static func prepareDirectory(_ directory: URL, synchronize: (Int32) throws -> Void) throws {
        guard directory.isFileURL else { throw BridgeError.invalid("Expected a private state directory URL.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var descriptor = try PrivateFile.openDirectory(directory)
        defer { close(descriptor) }
        // Repeat the complete chain even when directories already exist. An earlier
        // attempt may have created them and failed before syncing their parent entries.
        while true {
            try synchronize(descriptor)
            var current = stat(), above = stat()
            guard fstat(descriptor, &current) == 0 else { throw failure("Inspect state directory ancestor") }
            let parent = openat(descriptor, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw failure("Open state directory ancestor") }
            guard fstat(parent, &above) == 0 else {
                let error = failure("Inspect state directory parent")
                close(parent)
                throw error
            }
            if current.st_dev == above.st_dev && current.st_ino == above.st_ino {
                close(parent)
                return
            }
            close(descriptor)
            descriptor = parent
        }
    }

    private static func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else {
            throw BridgeError.invalid("State file must be a private, singly linked regular file owned by this user.")
        }
        try PrivateFile.rejectAccessGrants(fd)
    }

    public static func openLock(at file: URL) throws -> Int32 {
        try prepareDirectory(file.deletingLastPathComponent())
        let directory = try PrivateFile.openDirectory(file.deletingLastPathComponent())
        defer { close(directory) }
        var fd = openat(directory, file.lastPathComponent, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        let created = fd >= 0
        if fd < 0 && errno == EEXIST {
            fd = openat(directory, file.lastPathComponent, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fd >= 0 else { throw failure("Open state lock") }
        do {
            if created, fchmod(fd, 0o600) != 0 { throw failure("Set private state lock permissions") }
            try validate(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw BridgeError.invalid("Another companion owns the state file.") }
            return fd
        } catch { close(fd); throw error }
    }

    public static func read(at file: URL, maximumBytes: Int) throws -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw BridgeError.invalid("Invalid state byte budget.") }
        try prepareDirectory(file.deletingLastPathComponent())
        let directory = try PrivateFile.openDirectory(file.deletingLastPathComponent())
        defer { close(directory) }
        let fd = openat(directory, file.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw failure("Open state file")
        }
        defer { close(fd) }
        try validate(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size <= maximumBytes else { throw BridgeError.invalid("State file exceeds its byte budget.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw BridgeError.invalid("State file exceeds its byte budget.") }
        return data
    }

    public static func write(_ data: Data, to file: URL) throws {
        try write(data, to: file, inject: { _ in })
    }

    /// Injection points exercise failures on both sides of the visibility commit.
    static func write(_ data: Data, to file: URL, inject: (Stage) throws -> Void) throws {
        let directory = file.deletingLastPathComponent()
        try prepareDirectory(directory)
        let dir = try PrivateFile.openDirectory(directory)
        defer { close(dir) }
        // Reject unsafe existing targets rather than replacing unexpected filesystem objects.
        let existing = openat(dir, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if existing >= 0 {
            defer { close(existing) }
            try validate(existing)
        } else if errno != ENOENT { throw failure("Validate state destination") }
        let temporary = "." + file.lastPathComponent + "." + UUID().uuidString
        let fd = openat(dir, temporary, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("Create private state temporary") }
        defer { close(fd); unlinkat(dir, temporary, 0) }
        var committed = false
        do {
            guard fchmod(fd, 0o600) == 0 else { throw failure("Set private state temporary permissions") }
            try validate(fd)
            try inject(.temporaryCreated)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    #if canImport(Darwin)
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    #else
                    let count = Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    #endif
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw failure("Write state temporary") }
                    offset += count
                }
            }
            try inject(.written)
            guard fsync(fd) == 0 else { throw failure("Synchronize state temporary") }
            #if canImport(Darwin)
            // macOS fsync alone need not flush a drive's volatile write cache.
            guard fcntl(fd, F_FULLFSYNC) == 0 else { throw failure("Flush state temporary") }
            #endif
            try inject(.fileSynced)
            guard renameat(dir, temporary, dir, file.lastPathComponent) == 0 else { throw failure("Replace state file") }
            committed = true
            try inject(.renamed)
            guard fsync(dir) == 0 else { throw failure("Synchronize state directory") }
            try inject(.directorySynced)
        } catch {
            if committed { throw CommitError(underlying: error) }
            throw error
        }
    }
}
