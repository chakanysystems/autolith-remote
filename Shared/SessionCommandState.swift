import Foundation

/// Independent command ownership, including late completions after connection changes.
struct SessionCommandState {
    private var active: [String: UUID] = [:]

    func contains(_ sessionID: String) -> Bool { active[sessionID] != nil }

    mutating func begin(_ sessionID: String) -> UUID? {
        guard active[sessionID] == nil else { return nil }
        let token = UUID()
        active[sessionID] = token
        return token
    }

    mutating func finish(_ sessionID: String, token: UUID) {
        if active[sessionID] == token { active[sessionID] = nil }
    }

    mutating func clear() { active.removeAll() }
}
