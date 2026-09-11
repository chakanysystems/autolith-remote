import Foundation
import Darwin
import BridgeCore

/// Owns the launcher's process group until it is killed. The leader is deliberately
/// not reaped early, reserving its PID. Descendants that leave the group are not owned.
final class BackendChild {
    let input: Int32
    let output: Int32
    private var pid: pid_t
    private var inputClosed = false

    /// Call at daemon startup, before launching children. SIG_IGN/SA_NOCLDWAIT
    /// inherited from a launcher would otherwise release PIDs before stop().
    /// No other code may reap these children or change SIGCHLD afterward.
    static func prepareReaping() throws { try reapingPreparation.get() }

    private static let reapingPreparation: Result<Void, Error> = Result {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        guard sigaction(SIGCHLD, &action, nil) == 0 else {
            throw BridgeError.invalid("Cannot prepare backend child reaping.")
        }
    }

    private static func pipeDescriptors() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw BridgeError.invalid("Cannot create backend pipe.") }
        var succeeded = false
        defer { if !succeeded { descriptors.forEach { Darwin.close($0) } } }
        for index in descriptors.indices {
            let fd = descriptors[index]
            // Sources must never alias spawn's standard-descriptor destinations.
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, 3)
            guard moved >= 0 else { throw BridgeError.invalid("Cannot configure backend pipe.") }
            Darwin.close(fd)
            descriptors[index] = moved
        }
        succeeded = true
        return descriptors
    }
    init(executable: String) throws {
        try Self.prepareReaping()
        // Resolve stderr before pipe() can reuse a closed standard descriptor.
        var errorOutput = fcntl(STDERR_FILENO, F_DUPFD_CLOEXEC, 3)
        if errorOutput < 0 {
            guard errno == EBADF else { throw BridgeError.invalid("Cannot configure backend stderr.") }
            let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
            guard null >= 0 else { throw BridgeError.invalid("Cannot open backend stderr.") }
            errorOutput = fcntl(null, F_DUPFD_CLOEXEC, 3)
            Darwin.close(null)
            guard errorOutput >= 0 else { throw BridgeError.invalid("Cannot configure backend stderr.") }
        }
        defer { Darwin.close(errorOutput) }
        let incoming = try Self.pipeDescriptors()
        var outgoing: [Int32]
        do { outgoing = try Self.pipeDescriptors() }
        catch { incoming.forEach { Darwin.close($0) }; throw error }
        var succeeded = false
        defer {
            Darwin.close(incoming[0]); Darwin.close(outgoing[1])
            if !succeeded { Darwin.close(incoming[1]); Darwin.close(outgoing[0]) }
        }
        // CLOEXEC_DEFAULT prevents concurrent launches from inheriting pipe
        // descriptors during the interval between pipe() and fcntl().
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw BridgeError.invalid("Cannot prepare backend launch.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw BridgeError.invalid("Cannot prepare backend launch.") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorOutput, STDERR_FILENO) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw BridgeError.invalid("Cannot prepare backend launch.")
        }
        var allocated: [UnsafeMutablePointer<CChar>] = []
        defer { allocated.forEach { free($0) } }
        func copy(_ string: String) throws -> UnsafeMutablePointer<CChar> {
            guard let pointer = strdup(string) else { throw BridgeError.invalid("Cannot allocate backend launch arguments.") }
            allocated.append(pointer)
            return pointer
        }
        var argv: [UnsafeMutablePointer<CChar>?] = try [executable, "mobile"].map { try copy($0) }
        argv.append(nil)
        // Snapshot environment values instead of borrowing mutable libc environ.
        var environment: [UnsafeMutablePointer<CChar>?] = try ProcessInfo.processInfo.environment.map {
            try copy("\($0.key)=\($0.value)")
        }
        environment.append(nil)
        var child: pid_t = 0
        let result = executable.withCString { path in
            posix_spawn(&child, path, &actions, &attributes, &argv, &environment)
        }
        guard result == 0 else { throw BridgeError.invalid("Cannot start backend (\(result)).") }
        pid = child; input = incoming[1]; output = outgoing[0]
        succeeded = true
        guard fcntl(input, F_SETFL, O_NONBLOCK) != -1,
              fcntl(input, F_SETNOSIGPIPE, 1) != -1,
              fcntl(output, F_SETFL, O_NONBLOCK) != -1 else {
            stop(); throw BridgeError.invalid("Cannot configure backend pipe.")
        }
    }

    /// Caller must first cancel its queue-confined I/O. No delayed signal can
    /// target a subsequently reused group. Reaping never blocks the caller.
    func stop() {
        guard pid > 0 else { return }
        let ownedPID = pid
        pid = 0
        kill(-ownedPID, SIGTERM)
        closeInput(); Darwin.close(output)
        // Keep the leader unreaped throughout the grace period, including when
        // it exits before its children. Only reap after the final group signal.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            kill(-ownedPID, SIGKILL)
            var status: Int32 = 0
            while waitpid(ownedPID, &status, 0) < 0 && errno == EINTR {}
        }
    }
    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        Darwin.close(input)
    }
    deinit { stop() }
}
