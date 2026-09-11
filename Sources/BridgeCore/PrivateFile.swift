import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads credentials through validated descriptors, never by reopening a checked pathname.
public enum PrivateFile {
    public static func readSecret(at url: URL, maximumBytes: Int = 16_384) throws -> Data {
        guard url.isFileURL, maximumBytes > 0 else { throw BridgeError.invalid("Invalid credential file.") }
        let directory = try openDirectory(url.deletingLastPathComponent())
        defer { close(directory) }
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw BridgeError.invalid("Could not open the private credential file.") }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_uid == getuid(), attributes.st_mode & 0o7777 == 0o600,
              attributes.st_size >= 0, attributes.st_size <= maximumBytes else {
            throw BridgeError.invalid("Credential must be an owned regular file with mode 0600 and a bounded size.")
        }
        try rejectAccessGrants(descriptor)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes, 4096))
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw BridgeError.invalid("Could not read the private credential file.") }
            if count == 0 { return result }
            guard count <= maximumBytes - result.count else { throw BridgeError.invalid("Credential file exceeds its size limit.") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    /// The caller owns the returned directory descriptor. System path aliases are
    /// resolved before a descriptor-relative walk that rejects writable ancestors.
    public static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw BridgeError.invalid("Expected a private directory.") }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix("/") else { throw BridgeError.invalid("Expected an absolute directory.") }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw BridgeError.invalid("Could not open the filesystem root.") }
        do {
            for component in path.split(separator: "/") {
                let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw BridgeError.invalid("Could not open a trusted credential directory.") }
                close(descriptor)
                descriptor = next
                var attributes = stat()
                guard fstat(descriptor, &attributes) == 0,
                      attributes.st_uid == 0 || attributes.st_uid == getuid() else {
                    throw BridgeError.invalid("Credential directory ancestors must be owned by you or root.")
                }
                // A trusted sticky ancestor (for example /private/tmp) cannot have
                // an owned child replaced by another user.
                guard attributes.st_mode & 0o022 == 0 || attributes.st_mode & mode_t(S_ISVTX) != 0 else {
                    throw BridgeError.invalid("Credential directory ancestors must not be writable by other users.")
                }
                try rejectAccessGrants(descriptor)
            }
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0,
                  attributes.st_uid == getuid(), attributes.st_mode & 0o7777 == 0o700 else {
                throw BridgeError.invalid("Store credentials in an owned directory with mode 0700.")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Darwin ACL grants can override otherwise private POSIX modes. Deny entries
    /// (including the standard home-directory delete protection) are harmless.
    static func rejectAccessGrants(_ descriptor: Int32) throws {
        #if canImport(Darwin)
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP { return }
            throw BridgeError.invalid("Could not validate credential access controls.")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var position = ACL_FIRST_ENTRY
        while acl_get_entry(acl, position, &entry) == 0 {
            var tag = ACL_UNDEFINED_TAG
            guard let entry, acl_get_tag_type(entry, &tag) == 0, tag != ACL_EXTENDED_ALLOW else {
                throw BridgeError.invalid("Credential paths must not grant access through an extended ACL.")
            }
            position = ACL_NEXT_ENTRY
        }
        guard errno == EINVAL else { throw BridgeError.invalid("Could not inspect credential access controls.") }
        #endif
    }
}
