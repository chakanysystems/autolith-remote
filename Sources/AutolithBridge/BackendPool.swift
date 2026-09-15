import Foundation
import BridgeCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Serial management requests, with no retry after uncertain delivery.
final class BackendPool: @unchecked Sendable {
    private let slot = DispatchSemaphore(value: 1)
    private let socketPath: String
    private let tokenPath: String
    private let mappingFile: URL
    private let template: String
    private var connections: [String: ManagementRPC] = [:]
    private var endpoints: [String: String]
    private var gatewayID: String?

    init(socketPath: String, tokenPath: String, mappingFile: URL) throws {
        self.socketPath = socketPath; self.tokenPath = tokenPath; self.mappingFile = mappingFile
        guard let resource = Bundle.module.url(forResource: "Request", withExtension: "lisp") else {
            throw BridgeError.invalid("The companion's management request resource is missing.")
        }
        template = try String(contentsOf: resource, encoding: .utf8)
        if FileManager.default.fileExists(atPath: mappingFile.path) {
            let metadata = try FileManager.default.attributesOfItem(atPath: mappingFile.path)
            guard metadata[.type] as? FileAttributeType == .typeRegular,
                  (metadata[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (metadata[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (metadata[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else {
                throw BridgeError.invalid("Management endpoint inventory must be a private, owned regular file.")
            }
            endpoints = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mappingFile))
        } else { endpoints = [:] }
    }

    func checkConnection(context: BackendRequestContext = BackendRequestContext()) throws {
        try acquire(context); defer { slot.signal() }
        gatewayID = try exchange(["operation": "identity"], path: socketPath, context: context)["id"] as? String
        guard gatewayID != nil else { throw BridgeError.invalid("Management endpoint has no active Autolith session.") }
    }

    func call(_ request: Data, deadline: DispatchTime) throws -> Data {
        try call(request, context: BackendRequestContext(deadline: deadline))
    }

    func call(_ request: Data, context: BackendRequestContext = BackendRequestContext()) throws -> Data {
        try context.check()
        guard request.count <= 262144,
              var object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let operation = object["operation"] as? String,
              ["list", "create", "resume", "transcript", "catalog", "tell", "pause", "kill", "delete"].contains(operation) else {
            throw BridgeError.invalid("Unsupported management operation.")
        }
        try acquire(context); defer { slot.signal() }
        // Refresh after gateway restarts or conversation changes, before any mutation.
        gatewayID = try exchange(["operation": "identity"], path: socketPath, context: context)["id"] as? String
        object.removeValue(forKey: "managementSocket")
        object.removeValue(forKey: "requireCurrent")
        let id = object["id"] as? String
        guard id == nil || id != gatewayID else { throw BridgeError.invalid("The companion's gateway session is reserved for management.") }
        var path = socketPath
        if ["catalog", "transcript"].contains(operation), let id, let endpoint = endpoints[id],
           FileManager.default.fileExists(atPath: endpoint) {
            path = endpoint
            object["requireCurrent"] = true
        }
        var newSocket: String?
        if operation == "create" || operation == "resume" {
            // Adjacent to the private gateway socket, with a fixed-size generated name.
            newSocket = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString + ".sock").path
            guard newSocket!.utf8.count < 104 else {
                throw BridgeError.invalid("Use a shorter management socket directory before creating sessions.")
            }
            object["managementSocket"] = newSocket!
        }
        var response = try exchange(object, path: path, context: context)
        if operation == "list", let sessions = response["sessions"] as? [[String: Any]] {
            response["sessions"] = sessions.filter { $0["id"] as? String != gatewayID }
        }
        if let newSocket, let created = response["id"] as? String {
            endpoints[created] = newSocket
            do { try saveEndpoints() }
            catch { throw BridgeError.invalid("The session was created as \(created), but its management endpoint could not be saved. Refresh before retrying.") }
        }
        if operation == "delete", let id {
            if let endpoint = endpoints.removeValue(forKey: id) { connections.removeValue(forKey: endpoint) }
            try saveEndpoints()
        }
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func acquire(_ context: BackendRequestContext) throws {
        while true {
            try context.check()
            if slot.wait(timeout: min(context.deadline, .now() + 0.05)) == .success {
                do { try context.check(); return }
                catch { slot.signal(); throw error }
            }
        }
    }
    private func saveEndpoints() throws {
        try FileManager.default.createDirectory(at: mappingFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(endpoints).write(to: mappingFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mappingFile.path)
    }

    private func exchange(_ request: [String: Any], path: String, context: BackendRequestContext) throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let source = template.replacingOccurrences(of: "__REQUEST_JSON__", with: ManagementForm.quote(json))
        let connection: ManagementRPC
        if let existing = connections[path] { connection = existing }
        else {
            if connections.count >= 4 { connections.removeAll() }
            connection = ManagementRPC(socketPath: path, tokenPath: tokenPath)
            connections[path] = connection
        }
        let values = try connection.evaluate(source, context: context)
        guard values.count == 1,
              let json = try ManagementForm.parse(Data(values[0].utf8)).string,
              let response = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw BridgeError.invalid("Management RPC did not return a JSON object.")
        }
        return response
    }
}
