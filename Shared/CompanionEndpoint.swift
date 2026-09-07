import Foundation

/// A companion endpoint is an HTTPS origin, not a URL with a resource path.
enum CompanionEndpoint {
    enum Failure: LocalizedError {
        case invalidEndpoint

        var errorDescription: String? {
            "Enter an HTTPS Mac address with a host and optional port, without a path, credentials, query, or fragment."
        }
    }

    static func canonical(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URL(string: text, encodingInvalidCharacters: false),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@")) == nil,
              components.user == nil, components.password == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.query == nil, components.fragment == nil,
              components.url != nil else { throw Failure.invalidEndpoint }

        // Validate the explicit port too: URLComponents accepts an empty port.
        let authority = text.dropFirst("https://".count).split(separator: "/", omittingEmptySubsequences: false).first ?? ""
        if let separator = authority.lastIndex(of: ":"), !authority.hasSuffix("]") {
            let digits = authority[authority.index(after: separator)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let port = Int(digits), (1...65535).contains(port) else {
                throw Failure.invalidEndpoint
            }
            components.port = port
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        if components.port == 443 { components.port = nil }
        guard let result = components.string else { throw Failure.invalidEndpoint }
        return result
    }

    static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = try? canonical(lhs), let right = try? canonical(rhs) else { return false }
        return left == right
    }

    /// Preference keys can also contain older non-URL identifiers used by local clients.
    static func key(_ input: String) -> String {
        (try? canonical(input)) ?? input
    }

    static func canonicalEntityID(_ input: String) -> String {
        guard let separator = input.firstIndex(of: "#") else { return key(input) }
        return key(String(input[..<separator])) + String(input[separator...])
    }

    /// Existing canonical values take precedence when several old spellings map to one host.
    static func migratePreferences(defaults: UserDefaults = .standard) {
        let values = defaults.dictionaryRepresentation()
        for prefix in ["siriWorkspaces:", "siriLastSentSession:"] {
            for oldKey in values.keys.sorted() where oldKey.hasPrefix(prefix) {
                let host = String(oldKey.dropFirst(prefix.count))
                guard let canonicalHost = try? canonical(host) else { continue }
                let newKey = prefix + canonicalHost
                guard oldKey != newKey else { continue }
                if defaults.object(forKey: newKey) == nil {
                    defaults.set(values[oldKey], forKey: newKey)
                }
                defaults.removeObject(forKey: oldKey)
            }
        }
        if let host = defaults.string(forKey: "siriLatestSessionHost"),
           let canonicalHost = try? canonical(host), host != canonicalHost {
            defaults.set(canonicalHost, forKey: "siriLatestSessionHost")
        }
    }
}
