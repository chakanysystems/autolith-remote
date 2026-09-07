import AppIntents
import Foundation

struct AutolithWorkspaceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Autolith workspace"
    static var defaultQuery = AutolithWorkspaceQuery()
    let id: String
    let host: String
    let path: String
    var nickname: String = ""
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(nickname.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : nickname)", subtitle: "\(path)", synonyms: ["\(URL(fileURLWithPath: path).lastPathComponent)", "\(SiriWorkspaceRouting.normalized(URL(fileURLWithPath: path).lastPathComponent))"])
    }
    init(id: String, host: String, path: String, nickname: String = "") {
        self.id = CompanionEndpoint.canonicalEntityID(id)
        self.host = CompanionEndpoint.key(host)
        self.path = path
        self.nickname = nickname
    }
}

struct AutolithSessionEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Autolith session"
    static var defaultQuery = AutolithSessionQuery()
    let id: String
    let host: String
    let sessionID: String
    @Property(title: "Title") var title: String
    @Property(title: "Workspace") var workspace: String
    @Property(title: "Status") var status: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(workspace) · \(status)")
    }
    init(session: Session, host: String) {
        self.host = CompanionEndpoint.key(host)
        sessionID = session.id
        id = CompanionEndpoint.key(host) + "#" + session.id
        title = session.title
        workspace = session.workspace
        status = session.state
    }
}

@MainActor enum SiriSessionService {
    static func connected() throws -> Connection {
        let connection = Connection()
        _ = try connection.endpoint()
        return connection
    }
    static func sessions() async throws -> (Connection, [Session]) {
        SiriTrace.record("Sessions: requested")
        do {
            let connection = try connected()
            let sessions = try await connection.call(["operation": "list"]).sessions ?? []
            SiriTrace.record("Sessions: received", count: sessions.count)
            return (connection, sessions.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) })
        } catch {
            SiriTrace.record("Sessions: failed", errorCode: (error as NSError).code)
            throw error
        }
    }
    static func requireHost(_ host: String, connection: Connection) throws {
        guard CompanionEndpoint.equivalent(host, connection.host) else {
            throw connection.failure("This selection belongs to a different Mac. Choose a workspace or session from the connected Mac.")
        }
    }
}

struct AutolithWorkspaceQuery: EntityStringQuery {
    @MainActor func suggestedEntities() async throws -> [AutolithWorkspaceEntity] {
        let (connection, sessions) = try await SiriSessionService.sessions()
        let configuration = SiriWorkspaceConfiguration.load(host: connection.host)
        var seen = Set<String>()
        let paths = sessions.map(\.workspace) + Array(configuration.nicknames.keys).sorted() + [configuration.defaultPath].compactMap { $0 }
        return paths.compactMap { path in
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
            return AutolithWorkspaceEntity(id: connection.host + "#" + path, host: connection.host, path: path, nickname: configuration.nicknames[path] ?? "")
        }
    }
    func entities(for identifiers: [String]) async throws -> [AutolithWorkspaceEntity] {
        let canonicalIDs = Set(identifiers.map(CompanionEndpoint.canonicalEntityID))
        return try await suggestedEntities().filter { canonicalIDs.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [AutolithWorkspaceEntity] {
        let entities = try await suggestedEntities()
        let query = SiriWorkspaceRouting.normalized(string)
        let exact = entities.filter {
            [ $0.path, URL(fileURLWithPath: $0.path).lastPathComponent, $0.nickname ].contains { SiriWorkspaceRouting.normalized($0) == query }
        }
        return exact.isEmpty ? entities.filter { SiriWorkspaceRouting.normalized($0.path).contains(query) || SiriWorkspaceRouting.normalized($0.nickname).contains(query) } : exact
    }
}

struct AutolithSessionQuery: EntityStringQuery {
    @MainActor func suggestedEntities() async throws -> [AutolithSessionEntity] {
        let (connection, sessions) = try await SiriSessionService.sessions()
        return sessions.map { AutolithSessionEntity(session: $0, host: connection.host) }
    }
    func entities(for identifiers: [String]) async throws -> [AutolithSessionEntity] {
        let canonicalIDs = Set(identifiers.map(CompanionEndpoint.canonicalEntityID))
        return try await suggestedEntities().filter { canonicalIDs.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [AutolithSessionEntity] {
        try await suggestedEntities().filter {
            $0.title.localizedCaseInsensitiveContains(string) || $0.workspace.localizedCaseInsensitiveContains(string)
        }
    }
}
