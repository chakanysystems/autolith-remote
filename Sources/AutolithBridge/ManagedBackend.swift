import Foundation
import BridgeCore
import CBridgePOSIX
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns only the gateway it launches. Session endpoints and credentials survive restarts.
/// Call lifecycle methods on one serial queue.
final class ManagedBackend {
    let backend: BackendPool
    let socketPath: String
    let tokenPath: String
    let ownsGateway: Bool
    private let environment: [String: String]
    private var child: BackendChild?
    private var lockDescriptor: Int32 = -1
    var isRunning: Bool { !ownsGateway || child?.isRunning == true }

    init(environment: [String: String], tokenDirectory: URL) throws {
        self.environment = environment
        let socket = environment["AUTOLITH_MANAGEMENT_REPL_UNIX_SOCKET"]
        let token = environment["AUTOLITH_MANAGEMENT_REPL_TOKEN_FILE"]
        guard (socket == nil) == (token == nil) else {
            throw BridgeError.invalid("Set both management socket and token paths to use an existing REPL, or unset both to start one automatically.")
        }
        ownsGateway = socket == nil
        if let socket, let token {
            guard socket.hasPrefix("/"), token.hasPrefix("/") else {
                throw BridgeError.invalid("Management socket and token paths must be absolute.")
            }
            socketPath = socket; tokenPath = token
        } else {
            let parent = try PrivateFile.openDirectory(tokenDirectory)
            defer { close(parent) }
            guard mkdirat(parent, "gateway", 0o700) == 0 || errno == EEXIST else {
                throw BridgeError.invalid("Cannot create the private gateway directory.")
            }
            let directory = tokenDirectory.appendingPathComponent("gateway")
            let descriptor = openat(parent, "gateway", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw BridgeError.invalid("Invalid gateway directory.") }
            defer { close(descriptor) }
            let validated = try PrivateFile.openDirectory(directory)
            close(validated)
            // Reserve enough space for the per-session UUID socket names as well.
            guard directory.path.utf8.count + 42 < 104 else {
                throw BridgeError.invalid("Use a shorter companion token directory for management sockets.")
            }
            socketPath = directory.appendingPathComponent("repl.sock").path
            tokenPath = directory.appendingPathComponent("token").path
            let lock = openat(descriptor, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard lock >= 0 else { throw BridgeError.invalid("Cannot open gateway ownership lock.") }
            var attributes = stat()
            guard fstat(lock, &attributes) == 0, attributes.st_uid == getuid(),
                  attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  attributes.st_mode & 0o7777 == 0o600, bridge_lock_exclusive(lock) == 0 else {
                close(lock)
                throw BridgeError.invalid("Another bridge owns this gateway, or its lock file is not private.")
            }
            lockDescriptor = lock
            do {
                try Self.createToken(directory: descriptor)
                let bytes = try PrivateFile.readSecret(at: URL(fileURLWithPath: tokenPath), maximumBytes: 4096)
                guard !bytes.isEmpty else { throw BridgeError.invalid("The management token is empty.") }
            } catch { close(lock); lockDescriptor = -1; throw error }
        }
        do {
            backend = try BackendPool(socketPath: socketPath, tokenPath: tokenPath,
                                      mappingFile: tokenDirectory.appendingPathComponent("management-endpoints.json"))
        } catch {
            if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
            throw error
        }
    }

    func start(timeout: TimeInterval = 30,
               context suppliedContext: BackendRequestContext? = nil,
               ready: (BackendPool, BackendRequestContext) throws -> Void = { try $0.checkConnection(context: $1) }) throws {
        let context = suppliedContext ?? BackendRequestContext(deadline: .now() + timeout)
        if !ownsGateway { try ready(backend, context); return }
        guard child == nil, lockDescriptor >= 0 else { throw BridgeError.invalid("Gateway has already been started or stopped.") }
        do {
            try rejectActiveSocket()
            var env = environment
            env["AUTOLITH_SESSION_STYLE"] = "direct"
            env["AUTOLITH_MANAGEMENT_REPL"] = "on"
            env["AUTOLITH_MANAGEMENT_REPL_TRANSPORT"] = "unix"
            env["AUTOLITH_MANAGEMENT_REPL_UNIX_SOCKET"] = socketPath
            env["AUTOLITH_MANAGEMENT_REPL_TOKEN_FILE"] = tokenPath
            env["AUTOLITH_MANAGEMENT_REPL_TIMEOUT"] = "60"
            env["AUTOLITH_MANAGEMENT_REPL_MAX_OUTPUT"] = "8388608"
            env["AUTOLITH_MANAGEMENT_REPL_MAX_FRAME"] = "33554432"
            // The gateway has no terminal. Its stdin pipe stays open until stop().
            child = try BackendChild(executable: Self.executable(in: environment),
                                     arguments: ["--permissions", "ask"], environment: env,
                                     redirectOutputToStderr: true)
            while true {
                try context.check()
                guard child?.isRunning == true else { throw BridgeError.invalid("Autolith exited before its management REPL became ready. Check the backend diagnostic above.") }
                do {
                    try ready(backend, context)
                    guard child?.isRunning == true else { throw BridgeError.invalid("Autolith exited during startup.") }
                    return
                }
                catch {
                    if context.remaining <= 0 { throw error }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        } catch {
            stop()
            throw BridgeError.invalid("Cannot start the managed Autolith REPL: \(error.localizedDescription)")
        }
    }

    func stop() {
        child?.stopAndWait(); child = nil
        if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
    }

    deinit { stop() }

    private func rejectActiveSocket() throws {
        var attributes = stat()
        if lstat(socketPath, &attributes) != 0 {
            if errno == ENOENT { return }
            throw BridgeError.invalid("Cannot inspect the gateway socket.")
        }
        guard attributes.st_uid == getuid(), attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw BridgeError.invalid("The gateway socket path is occupied by an unsafe file.")
        }
        #if canImport(Darwin)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw BridgeError.invalid("Cannot inspect gateway socket state.") }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw BridgeError.invalid("Cannot configure gateway probe.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let bytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result < 0 && errno == ECONNREFUSED else {
            throw BridgeError.invalid("A gateway is already using this socket. Set both management paths to connect to it explicitly.")
        }
        // Autolith validates and removes the stale socket itself during startup.
    }

    private static func executable(in environment: [String: String]) throws -> String {
        if let path = environment["AUTOLITH_EXECUTABLE"] {
            guard path.hasPrefix("/"), access(path, X_OK) == 0 else {
                throw BridgeError.invalid("AUTOLITH_EXECUTABLE must name an executable absolute path.")
            }
            return path
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let path = String(directory) + "/autolith"
            if access(path, X_OK) == 0 { return path }
        }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nix-profile/bin/autolith").path
        guard access(path, X_OK) == 0 else {
            throw BridgeError.invalid("Install Autolith on PATH or set AUTOLITH_EXECUTABLE to its absolute path.")
        }
        return path
    }

    private static func createToken(directory: Int32) throws {
        let descriptor = openat(directory, "token", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor < 0 {
            if errno == EEXIST { return }
            throw BridgeError.invalid("Cannot create the management token.")
        }
        var complete = false
        defer {
            close(descriptor)
            if !complete { unlinkat(directory, "token", 0) }
        }
        var random = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BridgeError.invalid("Cannot write the management token.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw BridgeError.invalid("Cannot save the management token.") }
        complete = true
    }
}
