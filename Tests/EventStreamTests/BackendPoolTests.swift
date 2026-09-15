import XCTest
import Foundation
@testable import AutolithBridge

final class BackendPoolTests: XCTestCase {
    func testSlowGatewayDoesNotBlockManagedSession() throws {
        let gateway = try ManagementTestServer(), session = try ManagementTestServer()
        defer { gateway.stop(); session.stop() }
        let blocked = expectation(description: "gateway is listing")
        let listed = expectation(description: "list completed")
        let sent = expectation(description: "tell completed independently")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        gateway.serve { socket in
            try gateway.authenticate(socket)
            _ = try gateway.receive(socket)
            try gateway.reply(socket, ["id": "gateway"])
            _ = try gateway.receive(socket)
            blocked.fulfill()
            _ = release.wait(timeout: .now() + 5)
            try gateway.reply(socket, ["sessions": []])
        }
        session.serve { socket in
            try session.authenticate(socket)
            let request = try ManagementTestServer.request(session.receive(socket))
            XCTAssertEqual(request["operation"] as? String, "tell")
            XCTAssertEqual(request["requireCurrent"] as? Bool, true)
            try session.reply(socket, ["ok": true])
        }
        let mapping = gateway.directory.appendingPathComponent("map.json")
        try JSONEncoder().encode(["s": session.path]).write(to: mapping)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapping.path)
        let pool = try BackendPool(socketPath: gateway.path, tokenPath: gateway.tokenPath, mappingFile: mapping)
        DispatchQueue.global().async {
            defer { listed.fulfill() }
            do { _ = try pool.call(Data(#"{"operation":"list"}"#.utf8)) }
            catch { XCTFail("List failed: \(error)") }
        }
        wait(for: [blocked], timeout: 3)
        DispatchQueue.global().async {
            defer { sent.fulfill() }
            do { _ = try pool.call(Data(#"{"operation":"tell","id":"s","message":"hello"}"#.utf8)) }
            catch { XCTFail("Tell failed: \(error)") }
        }
        wait(for: [sent], timeout: 2)
        release.signal()
        wait(for: [listed], timeout: 3)
    }
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
        // The fixture serves no additional request: this must reuse the list snapshot.
        let cached = try JSONSerialization.jsonObject(with: pool.call(Data(#"{"operation":"list"}"#.utf8))) as? [String: Any]
        XCTAssertEqual((cached?["sessions"] as? [[String: String]])?.map { $0["id"] }, ["s"])
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
