import XCTest
import CBridgePOSIX
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import AutolithBridge

final class BackendPOSIXTests: XCTestCase {
    func testBrokenPipeWriteReturnsEPIPE() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(bridge_pipe(&descriptors), 0)
        guard descriptors[0] >= 0 else { return }
        close(descriptors[0])
        defer { close(descriptors[1]) }
        #if canImport(Darwin)
        XCTAssertNotEqual(fcntl(descriptors[1], F_SETNOSIGPIPE, 1), -1)
        #else
        XCTAssertNotEqual(fcntl(descriptors[1], F_GETFD) & FD_CLOEXEC, 0)
        #endif
        var byte: UInt8 = 1
        let written = bridge_write(descriptors[1], &byte, 1)
        let error = errno
        XCTAssertEqual(written, -1)
        XCTAssertEqual(error, EPIPE)
    }

    func testBackendDoesNotInheritUnmarkedDescriptor() throws {
        let descriptor = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let inherited = fcntl(descriptor, F_DUPFD, 64)
        XCTAssertGreaterThanOrEqual(inherited, 64)
        guard inherited >= 0 else { return }
        defer { close(inherited) }
        XCTAssertEqual(fcntl(inherited, F_GETFD) & FD_CLOEXEC, 0)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("backend")
        #if canImport(Darwin)
        let descriptorPath = "/dev/fd/\(inherited)"
        #else
        let descriptorPath = "/proc/self/fd/\(inherited)"
        #endif
        let script = """
        #!\(try fixtureShellPath())
        if test -e \(descriptorPath); then
            printf '%s\\n' '{"inherited":true}'
        else
            printf '%s\\n' '{"inherited":false}'
        fi > "$0.result"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let child = try BackendChild(executable: executable.path)
        defer { child.stop() }
        let resultFile = URL(fileURLWithPath: executable.path + ".result")
        let deadline = Date().addingTimeInterval(3)
        var reply = Data()
        repeat {
            reply = (try? Data(contentsOf: resultFile)) ?? Data()
            if !reply.contains(10) { Thread.sleep(forTimeInterval: 0.01) }
        } while !reply.contains(10) && Date() < deadline
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Bool])
        XCTAssertEqual(result["inherited"], false)
    }
}
