import Foundation

public enum BridgeError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public struct HTTPRequest {
    public let body: Data
    public let authorization: String
    public static func parse(_ data: Data) throws -> HTTPRequest? {
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
        let available = data.count - boundary.upperBound
        guard available >= count else { return nil }
        guard available == count else { throw BridgeError.invalid("Pipelining is unsupported") }
        return HTTPRequest(body: Data(data[boundary.upperBound...]), authorization: headers["authorization"] ?? "")
    }
}
