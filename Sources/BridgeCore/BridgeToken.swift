import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The phone-facing bearer credential. Explicit paths are read-only configuration.
public struct BridgeToken {
    public let file: URL
    public let value: String

    public init(environment: [String: String]) throws {
        if let explicit = environment["AUTOLITH_BRIDGE_TOKEN_FILE"] {
            file = URL(fileURLWithPath: explicit)
        } else {
            let state: String
            if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
                guard xdg.hasPrefix("/") else { throw BridgeError.invalid("XDG_STATE_HOME must be an absolute path.") }
                state = xdg
            } else {
                guard let home = environment["HOME"], home.hasPrefix("/") else {
                    throw BridgeError.invalid("Set HOME or XDG_STATE_HOME to an absolute path for the bridge token.")
                }
                state = home + "/.local/state"
            }
            let directory = URL(fileURLWithPath: state).appendingPathComponent("autolith-bridge")
            file = directory.appendingPathComponent("token")
            try PrivateFile.createDirectory(at: directory)
            let descriptor = try PrivateFile.openDirectory(directory)
            defer { close(descriptor) }
            try PrivateFile.createRandomToken(directory: descriptor, hexadecimal: true)
        }
        let data = try PrivateFile.readSecret(at: file)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BridgeError.invalid("Token file must contain UTF-8 text.")
        }
        value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count >= 32 else {
            throw BridgeError.invalid("Token must contain at least 32 random characters.")
        }
    }
}
