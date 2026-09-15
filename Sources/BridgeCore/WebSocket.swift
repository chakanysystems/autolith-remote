import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A validated HTTP upgrade. Validate `authorization` before sending `response`.
/// Pass bytes after `consumedBytes` to the frame decoder. No extensions are negotiated.
public struct WebSocketUpgrade {
    public let authorization: String
    public let acceptKey: String
    public let consumedBytes: Int
    public var response: Data {
        Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n".utf8)
    }

    /// Returns nil for incomplete headers. The limit includes the final CRLF pair.
    /// Rejects duplicate headers, HTTP bodies, and all paths except `/events`.
    public static func parse(_ data: Data, maximumHeaderBytes: Int = 8192) throws -> Self? {
        guard maximumHeaderBytes >= 4 else { throw BridgeError.invalid("Invalid header limit") }
        let prefix = Data(data.prefix(maximumHeaderBytes))
        guard let end = prefix.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count < maximumHeaderBytes else { throw BridgeError.invalid("Headers too large") }
            return nil
        }
        let bytes = prefix[..<end.lowerBound]
        guard bytes.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: bytes, encoding: .ascii) else { throw BridgeError.invalid("Invalid headers") }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first == "GET /events HTTP/1.1" else { throw BridgeError.invalid("Use GET /events HTTP/1.1") }
        let token = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw BridgeError.invalid("Invalid header") }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            guard !name.isEmpty, name.utf8.allSatisfy({ token.contains($0) }),
                  value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
                  headers[name.lowercased()] == nil else { throw BridgeError.invalid("Invalid or duplicate header") }
            headers[name.lowercased()] = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        func tokens(_ name: String) -> [String] {
            (headers[name] ?? "").lowercased().split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard let host = headers["host"], !host.isEmpty,
              tokens("upgrade").contains("websocket"), tokens("connection").contains("upgrade"),
              headers["sec-websocket-version"] == "13",
              let key = headers["sec-websocket-key"], let decoded = Data(base64Encoded: key),
              decoded.count == 16, decoded.base64EncodedString() == key,
              headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else {
            throw BridgeError.invalid("Invalid WebSocket upgrade")
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Self(authorization: headers["authorization"] ?? "", acceptKey: Data(digest).base64EncodedString(), consumedBytes: end.upperBound)
    }
}

public enum WebSocketEvent: Equatable {
    case text(String)
    case ping(Data)
    case pong(Data)
    case close(code: UInt16?, reason: String)
}

/// Incremental RFC 6455 client frame decoder. Only text application messages are supported.
/// The caller must answer ping and close events. A close or protocol error ends this decoder.
/// Frame and fragmented-message storage are bounded by `maximumMessageBytes` (plus header bytes).
public struct WebSocketDecoder {
    public let maximumMessageBytes: Int
    private var frame: [UInt8] = []
    private var needed = 2
    private var headerSize = 0
    private var payloadSize: Int?
    private var message: [UInt8] = []
    private var fragmented = false
    private var ended = false

    public init(maximumMessageBytes: Int = 256 * 1024) {
        self.maximumMessageBytes = max(0, min(maximumMessageBytes, Int.max - 14))
    }

    /// Feed any number of bytes, including partial or multiple frames.
    /// Throws BridgeError on malformed input. Do not reuse after a thrown error.
    public mutating func receive(_ data: Data) throws -> [WebSocketEvent] {
        guard !ended else { throw BridgeError.invalid("WebSocket is closed") }
        do { return try consume(data) }
        catch { ended = true; frame.removeAll(); message.removeAll(); throw error }
    }

    private mutating func consume(_ data: Data) throws -> [WebSocketEvent] {
        var events: [WebSocketEvent] = []
        var index = data.startIndex
        while index < data.endIndex || frame.count == needed {
            let count = min(needed - frame.count, data.endIndex - index)
            if count > 0 { frame.append(contentsOf: data[index..<(index + count)]); index += count }
            guard frame.count == needed else { break }
            if headerSize == 0 {
                let opcode = frame[0] & 15
                guard frame[0] & 0x70 == 0, frame[1] & 0x80 != 0,
                      [0, 1, 8, 9, 10].contains(opcode) else { throw BridgeError.invalid("Invalid WebSocket frame") }
                let short = Int(frame[1] & 127)
                if opcode >= 8 {
                    guard frame[0] & 0x80 != 0, short <= 125 else { throw BridgeError.invalid("Invalid control frame") }
                } else {
                    guard (opcode == 0 && fragmented) || (opcode == 1 && !fragmented) else {
                        throw BridgeError.invalid("Invalid continuation")
                    }
                }
                headerSize = 2 + (short == 126 ? 2 : short == 127 ? 8 : 0) + 4
                needed = headerSize
                continue
            }
            if payloadSize == nil {
                let short = Int(frame[1] & 127)
                var length = UInt64(short)
                if short >= 126 {
                    length = 0
                    for byte in frame[2..<(headerSize - 4)] { length = (length << 8) | UInt64(byte) }
                    guard (short == 126 && length >= 126) || (short == 127 && length >= 65536 && length < (UInt64(1) << 63)) else {
                        throw BridgeError.invalid("Invalid frame length")
                    }
                }
                let control = frame[0] & 8 != 0
                let limit = control ? 125 : maximumMessageBytes - message.count
                guard length <= UInt64(limit) else { throw BridgeError.invalid("WebSocket message too large") }
                payloadSize = Int(length)
                needed = headerSize + Int(length)
                if frame.count < needed { continue }
            }
            let opcode = frame[0] & 15
            let final = frame[0] & 0x80 != 0
            let mask = Array(frame[(headerSize - 4)..<headerSize])
            let payload = frame[headerSize...].enumerated().map { $0.element ^ mask[$0.offset % 4] }
            switch opcode {
            case 0, 1:
                message.append(contentsOf: payload)
                fragmented = !final
                if final {
                    guard let text = String(bytes: message, encoding: .utf8) else { throw BridgeError.invalid("Invalid UTF-8") }
                    events.append(.text(text)); message.removeAll(keepingCapacity: true)
                }
            case 9: events.append(.ping(Data(payload)))
            case 10: events.append(.pong(Data(payload)))
            case 8:
                guard payload.count != 1 else { throw BridgeError.invalid("Invalid close payload") }
                var code: UInt16?
                var reason = ""
                if payload.count >= 2 {
                    let value = UInt16(payload[0]) << 8 | UInt16(payload[1])
                    guard WebSocketEncoder.validCloseCode(value), let text = String(bytes: payload.dropFirst(2), encoding: .utf8) else {
                        throw BridgeError.invalid("Invalid close code or reason")
                    }
                    code = value; reason = text
                }
                events.append(.close(code: code, reason: reason)); ended = true
                frame.removeAll(); message.removeAll()
                return events
            default: break
            }
            frame.removeAll(keepingCapacity: true); needed = 2; headerSize = 0; payloadSize = nil
        }
        return events
    }
}

/// Encodes complete, unmasked server frames. Control payloads must fit in 125 bytes.
public enum WebSocketEncoder {
    public static func text(_ text: String) -> Data { frame(opcode: 1, payload: Data(text.utf8)) }
    public static func ping(_ payload: Data = Data()) throws -> Data { try control(opcode: 9, payload: payload) }
    public static func pong(_ payload: Data = Data()) throws -> Data { try control(opcode: 10, payload: payload) }
    public static func close(code: UInt16? = nil, reason: String = "") throws -> Data {
        guard (code != nil || reason.isEmpty), code.map(validCloseCode) ?? true else { throw BridgeError.invalid("Invalid close code") }
        var payload = Data()
        if let code { payload.append(UInt8(code >> 8)); payload.append(UInt8(code & 255)); payload.append(contentsOf: reason.utf8) }
        return try control(opcode: 8, payload: payload)
    }
    fileprivate static func validCloseCode(_ code: UInt16) -> Bool {
        (1000...1014).contains(code) && ![1004, 1005, 1006].contains(code) || (3000...4999).contains(code)
    }
    private static func control(opcode: UInt8, payload: Data) throws -> Data {
        guard payload.count <= 125 else { throw BridgeError.invalid("Control payload too large") }
        return frame(opcode: opcode, payload: payload)
    }
    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var data = Data([0x80 | opcode])
        if payload.count < 126 { data.append(UInt8(payload.count)) }
        else if payload.count <= 65535 {
            data.append(126); data.append(UInt8(payload.count >> 8)); data.append(UInt8(payload.count & 255))
        } else {
            data.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((length >> shift) & 255)) }
        }
        data.append(payload)
        return data
    }
}
