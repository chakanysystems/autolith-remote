import Foundation

public enum BridgeError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public struct HTTPRequest {
    public let body: Data
    public let authorization: String
    public let keepAlive: Bool
    public struct Header {
        public let authorization: String
        public let contentLength: Int
        public let bodyOffset: Int
        public let keepAlive: Bool
    }

    /// Complete framing validation before accepting a potentially slow request body.
    public static func parseHeader(_ data: Data) throws -> Header? {
        guard data.count <= 280_000 else { throw BridgeError.invalid("Request too large") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 8192 { throw BridgeError.invalid("Headers too large") }
            return nil
        }
        guard boundary.lowerBound <= 8192,
              let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw BridgeError.invalid("Invalid headers") }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "POST /rpc HTTP/1.1" else { throw BridgeError.invalid("Use POST /rpc") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw BridgeError.invalid("Invalid header") }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw BridgeError.invalid("Duplicate header") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let raw = headers["content-length"], let count = Int(raw), (0...262144).contains(count) else { throw BridgeError.invalid("Invalid content length") }
        let close = headers["connection"]?.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "close" } == true
        return Header(authorization: headers["authorization"] ?? "", contentLength: count, bodyOffset: boundary.upperBound, keepAlive: !close)
    }

    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard let header = try parseHeader(data) else { return nil }
        let available = data.count - header.bodyOffset
        guard available >= header.contentLength else { return nil }
        guard available == header.contentLength else { throw BridgeError.invalid("Pipelining is unsupported") }
        return HTTPRequest(body: Data(data[header.bodyOffset...]), authorization: header.authorization, keepAlive: header.keepAlive)
    }
}
