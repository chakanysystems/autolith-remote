import Foundation

struct SiriWorkspaceConfiguration: Codable, Equatable {
    var defaultPath: String?
    var nicknames: [String: String] = [:]

    static func load(host: String, defaults: UserDefaults = .standard) -> Self {
        CompanionEndpoint.migratePreferences(defaults: defaults)
        guard let data = defaults.data(forKey: "siriWorkspaces:" + CompanionEndpoint.key(host)),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(host: String, defaults: UserDefaults = .standard) throws {
        CompanionEndpoint.migratePreferences(defaults: defaults)
        defaults.set(try JSONEncoder().encode(self), forKey: "siriWorkspaces:" + CompanionEndpoint.key(host))
    }
}

enum SiriWorkspaceRouting {
    // Match explicit workspace references only. Mentioning a project while discussing
    // code is not sufficient to change where a task runs.
    static func candidates(request: String, paths: [String], configuration: SiriWorkspaceConfiguration) -> [String] {
        let references = references(in: request)
        if references.isEmpty {
            let text = normalized(request)
            return paths.filter { path in
                let names = [path, URL(fileURLWithPath: path).lastPathComponent, configuration.nicknames[path] ?? ""]
                return names.filter { !$0.isEmpty }.contains { name in
                    let escaped = NSRegularExpression.escapedPattern(for: normalized(name))
                    return text.range(of: "\\bin (?:the )?" + escaped + "[.!?]?$", options: .regularExpression) != nil
                }
            }
        }
        var result = Set<String>()
        for reference in references {
            let matches = paths.filter { path in
                let names = [path, URL(fileURLWithPath: path).lastPathComponent, configuration.nicknames[path] ?? ""]
                return names.filter { !$0.isEmpty }.contains { normalized($0) == reference }
            }
            // An unknown reference must not fall back to a different named workspace.
            guard !matches.isEmpty else { return [] }
            result.formUnion(matches)
        }
        return paths.filter { result.contains($0) }
    }
    static func hasUnresolvedReference(_ request: String) -> Bool {
        !references(in: request).isEmpty
    }
    private static func references(in request: String) -> [String] {
        let text = normalized(request)
        let patterns = [#"\bin (?:the )?([^,;.!?]+?) (?:workspace|project)\b"#, #"^in (?:the )?([^,;]+)[,;]"#]
        return patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                guard let range = Range($0.range(at: 1), in: text) else { return nil }
                return String(text[range]).replacingOccurrences(of: #" (?:workspace|project)$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            }
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
