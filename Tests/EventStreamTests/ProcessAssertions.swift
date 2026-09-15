import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An orphan can remain a zombie until the OS/container's reaper collects it.
/// A zombie has terminated, even though kill(pid, 0) still succeeds.
private func processHasTerminated(_ pid: pid_t) throws -> Bool {
    if kill(pid, 0) == -1 {
        guard errno == ESRCH else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return true
    }
    #if canImport(Darwin)
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return size == 0 || info.kp_proc.p_stat == SZOMB
    #else
    do {
        let stat = try String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)
        // The parenthesized command can itself contain spaces or parentheses.
        guard let end = stat.lastIndex(of: ")"),
              let state = stat[stat.index(after: end)...].split(separator: " ").first else {
            throw POSIXError(.EIO)
        }
        return state == "Z" || state == "X"
    } catch {
        if kill(pid, 0) == -1 && errno == ESRCH { return true }
        throw error
    }
    #endif
}

func assertProcessTerminates(_ pid: pid_t, timeout: TimeInterval,
                             file: StaticString = #filePath, line: UInt = #line) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
        if try processHasTerminated(pid) { return }
        Thread.sleep(forTimeInterval: 0.01)
    } while ProcessInfo.processInfo.systemUptime < deadline
    XCTAssertTrue(try processHasTerminated(pid), "Process \(pid) did not terminate", file: file, line: line)
}

/// Nix sandboxes provide the shell on PATH, not necessarily at /bin/sh.
func fixtureShellPath() throws -> String {
    #if canImport(Darwin)
    return "/bin/sh"
    #else
    for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("sh").path
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    throw POSIXError(.ENOENT)
    #endif
}

func fixtureSleepPath() -> String {
    #if canImport(Darwin)
    return "/bin/sleep"
    #else
    return "sleep"
    #endif
}
