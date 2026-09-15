import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ClientCore

final class BoundedHTTPTests: XCTestCase {
    func testDeclaredOverflowIsRejectedBeforeCompleteBodyArrives() async throws {
        let fixture = try HTTPFixture(response: Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 65\r\n\r\na".utf8), holdOpen: true)
        defer { fixture.stop() }
        await assertLengthError(fixture, limit: 64)
    }

    func testChunkedExactLimitAndOverflow() async throws {
        let response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n".utf8)
        let exact = try HTTPFixture(response: response)
        defer { exact.stop() }
        let (data, http) = try await BoundedHTTP.data(for: exact.request, limit: 6)
        XCTAssertEqual(data, Data("abcdef".utf8))
        XCTAssertEqual(http.statusCode, 200)
        let overflow = try HTTPFixture(response: response)
        defer { overflow.stop() }
        await assertLengthError(overflow, limit: 5)
    }

    func testCompressedDecodedOverflow() async throws {
        // gzip of 64 ASCII A bytes, smaller on the wire than the 32-byte limit.
        let compressed = try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAAAA3N0pAwAADxiTEFAAAAA"))
        XCTAssertLessThan(compressed.count, 32)
        let response = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: \(compressed.count)\r\nConnection: close\r\n\r\n".utf8) + compressed
        let fixture = try HTTPFixture(response: response)
        defer { fixture.stop() }
        await assertLengthError(fixture, limit: 32)
    }

    func testPreflightCancellation() async throws {
        let fixture = try HTTPFixture(response: Data(), holdOpen: true)
        defer { fixture.stop() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BoundedHTTP.data(for: fixture.request, limit: 64)
        }
        await assertCancelled(task)
    }

    func testInFlightCancellation() async throws {
        let received = expectation(description: "HTTP request received")
        let fixture = try HTTPFixture(response: Data("HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\na".utf8), holdOpen: true, received: { received.fulfill() })
        defer { fixture.stop() }
        let task = Task { try await BoundedHTTP.data(for: fixture.request, limit: 64) }
        await fulfillment(of: [received], timeout: 3)
        task.cancel()
        await assertCancelled(task)
    }

    private func assertLengthError(_ fixture: HTTPFixture, limit: Int, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await BoundedHTTP.data(for: fixture.request, limit: limit)
            XCTFail("Oversized HTTP body accepted", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum, file: file, line: line)
        }
    }

    private func assertCancelled(_ task: Task<(Data, HTTPURLResponse), Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled HTTP request completed", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, "Unexpected error: \(error)", file: file, line: line)
        }
    }
}

/// A single loopback HTTP response, with no external services or URLProtocol mocks.
private final class HTTPFixture {
    let request: URLRequest
    private let listener: Int32
    private let release = DispatchSemaphore(value: 0)
    private let finished = DispatchGroup()

    init(response: Data, holdOpen: Bool = false, received: @escaping () -> Void = {}) throws {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var ready = false
        defer { if !ready { close(descriptor) } }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 1) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        request = URLRequest(url: URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/")!, timeoutInterval: 3)
        listener = descriptor
        ready = true
        let release = self.release, finished = self.finished
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pending, 1, 3000) > 0 else { return }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            guard fcntl(client, F_SETFL, 0) == 0 else { return }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            #if canImport(Darwin)
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                var byte: UInt8 = 0
                guard recv(client, &byte, 1, 0) == 1, header.count < 8192 else { return }
                header.append(byte)
            }
            received()
            response.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    #if canImport(Darwin)
                    let count = send(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    #else
                    let count = send(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                    #endif
                    guard count > 0 else { return }
                    offset += count
                }
            }
            if holdOpen { _ = release.wait(timeout: .now() + 5) }
        }
    }

    func stop() {
        release.signal()
        shutdown(listener, Int32(SHUT_RDWR))
        finished.wait()
        close(listener)
    }
}
