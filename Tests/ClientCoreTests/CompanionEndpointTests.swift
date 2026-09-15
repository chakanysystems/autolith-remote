import Foundation
import XCTest
@testable import ClientCore

final class CompanionEndpointTests: XCTestCase {
    func testEquivalentEndpointSpellings() throws {
        for spelling in ["https://mac.example", "HTTPS://MAC.Example/", " https://Mac.Example:443/\n"] {
            XCTAssertEqual(try CompanionEndpoint.canonical(spelling), "https://mac.example")
            XCTAssertTrue(CompanionEndpoint.equivalent(spelling, "https://mac.example"))
        }
        XCTAssertEqual(try CompanionEndpoint.canonical("HTTPS://MAC.Example:8443/"), "https://mac.example:8443")
        XCTAssertEqual(try CompanionEndpoint.canonical("https://[::1]:443/"), "https://[::1]")
        XCTAssertFalse(CompanionEndpoint.equivalent("https://mac.example:8443", "https://mac.example"))
        XCTAssertFalse(CompanionEndpoint.equivalent("https://other.example", "https://mac.example"))
    }

    func testRejectsNonOriginURLsAndInvalidPorts() {
        for input in [
            "", "mac.example", "http://mac.example", "https:///", "https://:443",
            "https://user@mac.example", "https://user:password@mac.example", "https://@mac.example",
            "https://mac.example/path", "https://mac.example//", "https://mac.example/%2F",
            "https://mac.example?", "https://mac.example?q=1", "https://mac.example#", "https://mac.example#fragment",
            "https://mac.example:", "https://mac.example:/", "https://mac.example:0", "https://mac.example:65536",
            "https://mac.example:-1", "https://mac.example:abc", "https://mac.example:999999999999999999999999",
            "https://bad host", "https://bad%20host", "https://bad%host", "https://bad<host", "https://mac.example\n.evil"
        ] {
            XCTAssertThrowsError(try CompanionEndpoint.canonical(input), input)
            XCTAssertFalse(CompanionEndpoint.equivalent(input, input), input)
        }
    }

    func testLegacyEntityIDsKeepTheirSuffix() {
        XCTAssertEqual(CompanionEndpoint.canonicalEntityID("HTTPS://MAC.Example:443/#/project#folder"), "https://mac.example#/project#folder")
        XCTAssertEqual(CompanionEndpoint.canonicalEntityID("https://MAC.Example/#session-1"), "https://mac.example#session-1")
        XCTAssertEqual(CompanionEndpoint.canonicalEntityID("opaque-id"), "opaque-id")
        XCTAssertEqual(CompanionEndpoint.canonicalEntityID("mac-a#session-1"), "mac-a#session-1")
    }

    func testMigratesHostScopedPreferences() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let oldHost = " HTTPS://MAC.Example:443/ "
        let host = "https://mac.example"
        let configuration = SiriWorkspaceConfiguration(defaultPath: "/project", nicknames: ["/project": "work"])
        defaults.set(try JSONEncoder().encode(configuration), forKey: "siriWorkspaces:" + oldHost)
        defaults.set("sent", forKey: "siriLastSentSession:" + oldHost)
        defaults.set("latest", forKey: "siriLatestSessionID")
        defaults.set(oldHost, forKey: "siriLatestSessionHost")

        CompanionEndpoint.migratePreferences(defaults: defaults)
        XCTAssertEqual(SiriWorkspaceConfiguration.load(host: host, defaults: defaults), configuration)
        XCTAssertEqual(SiriConversationMemory.lastSentIdentifier(host: host, defaults: defaults), "sent")
        XCTAssertEqual(SiriConversationMemory.identifier(host: host, defaults: defaults), "latest")
        XCTAssertEqual(defaults.string(forKey: "siriLatestSessionHost"), host)
        XCTAssertNil(defaults.object(forKey: "siriWorkspaces:" + oldHost))
        XCTAssertNil(defaults.object(forKey: "siriLastSentSession:" + oldHost))
        XCTAssertNil(SiriConversationMemory.identifier(host: "https://other.example", defaults: defaults))
    }

    func testMigrationPreservesCanonicalPreferencesAndIsIdempotent() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let canonicalHost = "https://mac.example"
        let legacyHost = "HTTPS://MAC.Example:443/"
        let canonicalConfiguration = SiriWorkspaceConfiguration(defaultPath: "/canonical")
        let legacyConfiguration = SiriWorkspaceConfiguration(defaultPath: "/legacy")
        defaults.set(try JSONEncoder().encode(canonicalConfiguration), forKey: "siriWorkspaces:" + canonicalHost)
        defaults.set(try JSONEncoder().encode(legacyConfiguration), forKey: "siriWorkspaces:" + legacyHost)
        defaults.set("canonical", forKey: "siriLastSentSession:" + canonicalHost)
        defaults.set("legacy", forKey: "siriLastSentSession:" + legacyHost)
        defaults.set("latest", forKey: "siriLatestSessionID")
        defaults.set(canonicalHost, forKey: "siriLatestSessionHost")
        defaults.set("local", forKey: "siriLastSentSession:mac-a")

        CompanionEndpoint.migratePreferences(defaults: defaults)
        CompanionEndpoint.migratePreferences(defaults: defaults)
        XCTAssertEqual(SiriWorkspaceConfiguration.load(host: legacyHost, defaults: defaults), canonicalConfiguration)
        XCTAssertEqual(SiriConversationMemory.lastSentIdentifier(host: legacyHost, defaults: defaults), "canonical")
        XCTAssertEqual(SiriConversationMemory.identifier(host: legacyHost, defaults: defaults), "latest")
        XCTAssertEqual(SiriConversationMemory.lastSentIdentifier(host: "mac-a", defaults: defaults), "local")
    }

    func testStoresUseOneKeyForEquivalentHosts() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let canonicalHost = "https://mac.example"
        let legacyHost = "HTTPS://MAC.Example:443/"
        let configuration = SiriWorkspaceConfiguration(defaultPath: "/project")
        try configuration.save(host: legacyHost, defaults: defaults)
        SiriConversationMemory.sent(id: "sent", host: legacyHost, defaults: defaults)
        XCTAssertEqual(SiriWorkspaceConfiguration.load(host: canonicalHost, defaults: defaults), configuration)
        XCTAssertEqual(SiriConversationMemory.lastSentIdentifier(host: canonicalHost, defaults: defaults), "sent")
        XCTAssertEqual(SiriConversationMemory.identifier(host: canonicalHost, defaults: defaults), "sent")
        XCTAssertNil(defaults.object(forKey: "siriWorkspaces:" + legacyHost))
        XCTAssertNil(defaults.object(forKey: "siriLastSentSession:" + legacyHost))
        XCTAssertNil(SiriConversationMemory.lastSentIdentifier(host: "https://mac.example:8443", defaults: defaults))
    }
}
