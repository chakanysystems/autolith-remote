import XCTest
import Foundation
@testable import AutolithBridge

final class BackendPoolTests: XCTestCase {
    func testRoutesJSONWithoutReaderInjectionAndReusesConnection() throws {
        let server = try ManagementTestServer()
        defer { server.stop() }
        let complete = expectation(description: "requests")
        let message = "\") (error \"injected\") ;\nλ\\"
        server.serve { socket in
            defer { complete.fulfill() }
            try server.authenticate(socket)
            XCTAssertEqual(try ManagementTestServer.request(server.receive(socket))["operation"] as? String, "identity")
            try server.reply(socket, ["id": "gateway"])
            let request = try ManagementTestServer.request(server.receive(socket))
            XCTAssertEqual(request["operation"] as? String, "tell")
            XCTAssertEqual(request["message"] as? String, message)
            XCTAssertNil(request["managementSocket"])
            XCTAssertNil(request["requireCurrent"])
            try server.reply(socket, ["ok": true])
            XCTAssertEqual(try ManagementTestServer.request(server.receive(socket))["operation"] as? String, "identity")
            try server.reply(socket, ["id": "gateway"])
            XCTAssertEqual(try ManagementTestServer.request(server.receive(socket))["operation"] as? String, "list")
            try server.reply(socket, ["sessions": [["id": "gateway"], ["id": "s"]]])
        }
        let pool = try BackendPool(socketPath: server.path, tokenPath: server.tokenPath,
                                   mappingFile: server.directory.appendingPathComponent("map.json"))
        _ = try pool.call(JSONSerialization.data(withJSONObject: ["operation": "tell", "id": "s", "message": message,
            "managementSocket": "/untrusted", "requireCurrent": true]))
        let reply = try JSONSerialization.jsonObject(with: pool.call(Data(#"{"operation":"list"}"#.utf8))) as? [String: Any]
        XCTAssertEqual((reply?["sessions"] as? [[String: String]])?.map { $0["id"] }, ["s"])
        wait(for: [complete], timeout: 5)
    }

    func testRejectsArbitraryOperationsBeforeConnecting() throws {
        let server = try ManagementTestServer()
        defer { server.stop() }
        let pool = try BackendPool(socketPath: server.path, tokenPath: server.tokenPath,
                                   mappingFile: server.directory.appendingPathComponent("map.json"))
        for operation in ["evaluate", "identity", "stop-idle", "rpc-handshake"] {
            XCTAssertThrowsError(try pool.call(JSONSerialization.data(withJSONObject: ["operation": operation])))
        }
    }
}
