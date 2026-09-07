import Foundation
import XCTest
@testable import BridgeCore

final class WebSocketTests: XCTestCase {
    private let request = "GET /events HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nAuthorization: Bearer test\r\n\r\n"

    private func masked(_ bytes: [UInt8], opcode: UInt8 = 1, final: Bool = true) -> Data {
        var data = Data([opcode | (final ? 0x80 : 0)])
        if bytes.count < 126 { data.append(0x80 | UInt8(bytes.count)) }
        else if bytes.count <= 65535 {
            data.append(0xfe); data.append(UInt8(bytes.count >> 8)); data.append(UInt8(bytes.count & 255))
        } else {
            data.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((UInt64(bytes.count) >> shift) & 255)) }
        }
        let mask: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]
        data.append(contentsOf: mask)
        data.append(contentsOf: bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return data
    }

    func testRFCUpgradeAndPartialHeader() throws {
        let data = Data(request.utf8)
        for count in 0..<data.count { XCTAssertNil(try WebSocketUpgrade.parse(data.prefix(count))) }
        let upgrade = try XCTUnwrap(WebSocketUpgrade.parse(data + masked(Array("Hi".utf8))))
        XCTAssertEqual(upgrade.acceptKey, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertEqual(upgrade.authorization, "Bearer test")
        XCTAssertEqual(upgrade.consumedBytes, data.count)
        XCTAssertTrue(String(decoding: upgrade.response, as: UTF8.self).contains("101 Switching Protocols\r\n"))
    }

    func testInvalidUpgradesAndBounds() throws {
        for invalid in [
            request.replacingOccurrences(of: "GET /events", with: "POST /events"),
            request.replacingOccurrences(of: "/events", with: "/rpc"),
            request.replacingOccurrences(of: "Version: 13", with: "Version: 12"),
            request.replacingOccurrences(of: "Upgrade: websocket", with: "Upgrade: h2c"),
            request.replacingOccurrences(of: "keep-alive, Upgrade", with: "keep-alive"),
            request.replacingOccurrences(of: "dGhlIHNhbXBsZSBub25jZQ==", with: "YWJj"),
            request.replacingOccurrences(of: "Host: localhost", with: "Host: localhost\r\nHost: other"),
            request.replacingOccurrences(of: "Host: localhost", with: "Host : localhost"),
            request.replacingOccurrences(of: "Host: localhost", with: "Host: localhost\nInjected: yes"),
            request.replacingOccurrences(of: "Host: localhost", with: "Host: localhost\r\nTransfer-Encoding: chunked"),
            request.replacingOccurrences(of: "Host: localhost", with: "Host: localhost\r\nContent-Length: 1")
        ] { XCTAssertThrowsError(try WebSocketUpgrade.parse(Data(invalid.utf8))) }
        XCTAssertThrowsError(try WebSocketUpgrade.parse(Data(repeating: 65, count: 8192)))
        XCTAssertThrowsError(try WebSocketUpgrade.parse(Data(request.utf8), maximumHeaderBytes: 32))
    }

    func testRFCMaskedFrameAndEverySplit() throws {
        let frame = Data([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58])
        for split in 0...frame.count {
            var decoder = WebSocketDecoder()
            let first = try decoder.receive(frame.prefix(split))
            let second = try decoder.receive(frame.dropFirst(split))
            XCTAssertEqual(first + second, [.text("Hello")])
        }
    }

    func testFragmentedUTF8WithControlFrames() throws {
        var decoder = WebSocketDecoder()
        let wire = masked([0xe2], final: false) + masked([42], opcode: 9)
            + masked([0x82], opcode: 0, final: false) + masked([42], opcode: 10)
            + masked([0xac], opcode: 0)
        var events: [WebSocketEvent] = []
        for byte in wire { events += try decoder.receive(Data([byte])) }
        XCTAssertEqual(events, [.ping(Data([42])), .pong(Data([42])), .text("€")])
    }

    func testCloseAndServerEncoding() throws {
        var decoder = WebSocketDecoder()
        XCTAssertEqual(try decoder.receive(masked([3, 232, 98, 121, 101], opcode: 8)), [.close(code: 1000, reason: "bye")])
        XCTAssertThrowsError(try decoder.receive(masked([])))
        var empty = WebSocketDecoder()
        XCTAssertEqual(try empty.receive(masked([], opcode: 8)), [.close(code: nil, reason: "")])
        XCTAssertEqual(WebSocketEncoder.text("Hello"), Data([0x81, 5, 72, 101, 108, 108, 111]))
        XCTAssertEqual(try WebSocketEncoder.ping(Data([1])), Data([0x89, 1, 1]))
        XCTAssertEqual(try WebSocketEncoder.pong(), Data([0x8a, 0]))
        XCTAssertEqual(try WebSocketEncoder.close(code: 1000), Data([0x88, 2, 3, 232]))
        XCTAssertThrowsError(try WebSocketEncoder.close(code: 1005))
        XCTAssertThrowsError(try WebSocketEncoder.close(reason: "missing code"))
        XCTAssertThrowsError(try WebSocketEncoder.ping(Data(repeating: 0, count: 126)))
        XCTAssertThrowsError(try WebSocketEncoder.close(code: 1000, reason: String(repeating: "a", count: 124)))
    }

    func testMalformedFrames() throws {
        let invalid = [
            Data([0x81, 0]), Data([0xc1, 0x80]), Data([0x82, 0x80]), Data([0x83, 0x80]),
            Data([0x09, 0x80]), Data([0x89, 0xfe]), masked([], opcode: 0),
            masked([0xff]), masked([1], opcode: 8), masked([3, 237], opcode: 8),
            masked([3, 232, 0xff], opcode: 8),
            Data([0x81, 0xfe, 0, 1, 0, 0, 0, 0]),
            Data([0x81, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            Data([0x81, 0xff, 0, 0, 0, 0, 0, 0, 0, 126, 0, 0, 0, 0])
        ]
        for wire in invalid {
            var decoder = WebSocketDecoder()
            XCTAssertThrowsError(try decoder.receive(wire), "\(wire as NSData)")
            XCTAssertThrowsError(try decoder.receive(masked([])))
        }
        var decoder = WebSocketDecoder()
        _ = try decoder.receive(masked([], final: false))
        XCTAssertThrowsError(try decoder.receive(masked([])))
    }

    func testMessageBoundsAndExtendedLengths() throws {
        for size in [0, 125, 126, 65535, 65536, 262144] {
            let text = String(repeating: "a", count: size)
            var decoder = WebSocketDecoder()
            let wire = masked(Array(text.utf8))
            XCTAssertEqual(try decoder.receive(wire), [.text(text)])
            let encoded = WebSocketEncoder.text(text)
            XCTAssertEqual(encoded.first, 0x81)
            XCTAssertEqual(encoded.count, size + (size < 126 ? 2 : size <= 65535 ? 4 : 10))
        }
        var tooLarge = WebSocketDecoder()
        // Declared length is rejected before any payload is buffered.
        XCTAssertThrowsError(try tooLarge.receive(Data([0x81, 0xff, 0, 0, 0, 0, 0, 4, 0, 1, 0, 0, 0, 0])))
        var fragmented = WebSocketDecoder(maximumMessageBytes: 3)
        _ = try fragmented.receive(masked([65, 66], final: false))
        XCTAssertThrowsError(try fragmented.receive(masked([67, 68], opcode: 0)))
        var many = WebSocketDecoder(maximumMessageBytes: 1)
        let wire = (0..<1000).reduce(into: Data()) { result, _ in result.append(masked([65])) }
        XCTAssertEqual(try many.receive(wire).count, 1000)
    }
}
