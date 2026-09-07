import XCTest
@testable import BridgeCore
final class HTTPRequestTests: XCTestCase {
    func testSplitBodyAndUnicode() throws {
        let body = Data("{\"message\":\"hello 👋\"}".utf8)
        let head = Data("POST /rpc HTTP/1.1\r\nContent-Length: \(body.count)\r\nAuthorization: Bearer secret\r\n\r\n".utf8)
        XCTAssertNil(try HTTPRequest.parse(head + body.prefix(3)))
        let request = try XCTUnwrap(HTTPRequest.parse(head + body))
        XCTAssertEqual(request.body, body)
        XCTAssertEqual(request.authorization, "Bearer secret")
    }
    func testRejectsAmbiguousFraming() {
        for header in ["Content-Length: -1", "Content-Length: 262145", "Content-Length: 0\r\nContent-Length: 0", "Content-Length: 0\r\nTransfer-Encoding: chunked"] {
            XCTAssertThrowsError(try HTTPRequest.parse(Data("POST /rpc HTTP/1.1\r\n\(header)\r\n\r\n".utf8)))
        }
    }
    func testRejectsPipeliningAndOversizedHeaders() {
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST /rpc HTTP/1.1\r\nContent-Length: 0\r\n\r\nx".utf8)))
        XCTAssertThrowsError(try HTTPRequest.parse(Data(repeating: 65, count: 8193)))
    }
}
