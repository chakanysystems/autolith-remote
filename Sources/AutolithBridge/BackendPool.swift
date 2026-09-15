import Foundation
import BridgeCore
import ClientCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Serialize each endpoint independently. Never retry uncertain mutations.
final class BackendPool: @unchecked Sendable {
    private final class Endpoint {
        let slot = DispatchSemaphore(value: 1)
        let connection: ManagementRPC
        var users = 0
        var accessed = ProcessInfo.processInfo.systemUptime
        init(path: String, tokenPath: String) { connection = ManagementRPC(socketPath: path, tokenPath: tokenPath) }
    }
    private let lock = NSLock()
    private let socketPath: String
    private let tokenPath: String
    private let mappingFile: URL
    private let template: String
    private var connections: [String: Endpoint] = [:]
    private var endpoints: [String: String]
    private var gatewayID: String?
    private var listSnapshot: (data: Data, expires: TimeInterval)?
    private let projections = TranscriptProjectionCache()

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
        try withEndpoint(socketPath, context: context) { connection in
            let id = try exchange(["operation": "identity"], connection: connection, context: context)["id"] as? String
            guard id != nil else { throw BridgeError.invalid("Management endpoint has no active Autolith session.") }
            lock.lock(); gatewayID = id; lock.unlock()
        }
    }

    func call(_ request: Data, deadline: DispatchTime) throws -> Data {
        try call(request, context: BackendRequestContext(deadline: deadline))
    }

    func call(_ request: Data, context: BackendRequestContext = BackendRequestContext()) throws -> Data {
        if let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
           object["operation"] as? String == "transcript", let id = object["id"] as? String,
           (object["after"] as? Int ?? 0) == 0 {
            return try projections.load(sessionID: id, context: context,
                source: { try self.transcriptRevision(id, context: context) },
                fetch: { try self.perform(request, context: context) })
        }
        return try perform(request, context: context)
    }

    func transcriptRevision(_ id: String, context: BackendRequestContext) throws -> String {
        try TranscriptSource.revision(transcriptSource(id, context: context))
    }

    func watchSnapshot(_ id: String, context: BackendRequestContext) throws -> [String: Any] {
        let source = try transcriptSource(id, context: context)
        guard let status = source["status"] as? [String: Any] else { throw BridgeError.invalid("Session is no longer available.") }
        return ["status": status, "transcriptRevision": try TranscriptSource.revision(source)]
    }

    private func transcriptSource(_ id: String, context: BackendRequestContext) throws -> [String: Any] {
        let data = try perform(JSONSerialization.data(withJSONObject: ["operation": "transcript-source", "id": id]), context: context)
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.invalid("Invalid transcript source.") }
        if let error = source["error"] as? String { throw BridgeError.invalid(error) }
        return source
    }

    private func perform(_ request: Data, context: BackendRequestContext) throws -> Data {
        try context.check()
        guard request.count <= 262144,
              var object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let operation = object["operation"] as? String,
              ["list", "create", "resume", "transcript", "transcript-source", "catalog", "tell", "pause", "kill", "delete"].contains(operation) else {
            throw BridgeError.invalid("Unsupported management operation.")
        }
        object.removeValue(forKey: "managementSocket")
        object.removeValue(forKey: "requireCurrent")
        let id = object["id"] as? String
        lock.lock()
        let endpoint = id.flatMap { endpoints[$0] }
        let reserved = gatewayID
        lock.unlock()
        guard id == nil || id != reserved else { throw BridgeError.invalid("The companion's gateway session is reserved for management.") }
        var path = socketPath
        if ["catalog", "transcript", "transcript-source", "tell", "pause"].contains(operation), let endpoint,
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
        let mutation = !["list", "catalog", "transcript", "transcript-source"].contains(operation)
        if mutation { invalidateList() }
        defer { if mutation { invalidateList() } }
        return try withEndpoint(path, context: context) { connection in
        if operation == "list" {
            lock.lock(); let cached = listSnapshot; lock.unlock()
            if let cached, cached.expires > ProcessInfo.processInfo.systemUptime { return cached.data }
        }
        var currentGateway = reserved
        if path == socketPath {
            currentGateway = try exchange(["operation": "identity"], connection: connection, context: context)["id"] as? String
            lock.lock(); gatewayID = currentGateway; lock.unlock()
            guard id == nil || id != currentGateway else { throw BridgeError.invalid("The companion's gateway session is reserved for management.") }
        }
        var response = try exchange(object, connection: connection, context: context)
        if operation == "list", let sessions = response["sessions"] as? [[String: Any]] {
            response["sessions"] = sessions.filter { $0["id"] as? String != currentGateway }
        }
        if let newSocket, let created = response["id"] as? String {
            lock.lock(); defer { lock.unlock() }
            endpoints[created] = newSocket
            do { try saveEndpoints() }
            catch { throw BridgeError.invalid("The session was created as \(created), but its management endpoint could not be saved. Refresh before retrying.") }
        }
        if operation == "delete", let id {
            lock.lock(); defer { lock.unlock() }
            if let endpoint = endpoints.removeValue(forKey: id) { connections.removeValue(forKey: endpoint) }
            try saveEndpoints()
        }
        let data = try JSONSerialization.data(withJSONObject: response)
        if operation == "list", response["error"] == nil {
            lock.lock(); listSnapshot = (data, ProcessInfo.processInfo.systemUptime + 1); lock.unlock()
        }
        return data
        }
    }

    private func invalidateList() {
        lock.lock(); listSnapshot = nil; lock.unlock()
    }

    private func withEndpoint<T>(_ path: String, context: BackendRequestContext, operation: (ManagementRPC) throws -> T) throws -> T {
        lock.lock()
        let endpoint: Endpoint
        if let existing = connections[path] { endpoint = existing }
        else {
            if connections.count >= 16, let oldest = connections.filter({ $0.value.users == 0 }).min(by: { $0.value.accessed < $1.value.accessed }) {
                connections[oldest.key] = nil
            }
            endpoint = Endpoint(path: path, tokenPath: tokenPath)
            connections[path] = endpoint
        }
        endpoint.users += 1
        lock.unlock()
        defer { lock.lock(); endpoint.users -= 1; endpoint.accessed = ProcessInfo.processInfo.systemUptime; lock.unlock() }
        try acquire(endpoint.slot, context: context)
        defer { endpoint.slot.signal() }
        return try operation(endpoint.connection)
    }

    private func acquire(_ slot: DispatchSemaphore, context: BackendRequestContext) throws {
        let interval = PerformanceInterval(.backendWait)
        defer { interval.finish() }
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

    private func exchange(_ request: [String: Any], connection: ManagementRPC, context: BackendRequestContext) throws -> [String: Any] {
        let interval = PerformanceInterval(.backendRPC)
        defer { interval.finish() }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let source = template.replacingOccurrences(of: "__REQUEST_JSON__", with: ManagementForm.quote(json))
        let values = try connection.evaluate(source, context: context)
        guard values.count == 1,
              let json = try ManagementForm.parse(Data(values[0].utf8)).string,
              let response = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw BridgeError.invalid("Management RPC did not return a JSON object.")
        }
        return response
    }
}
