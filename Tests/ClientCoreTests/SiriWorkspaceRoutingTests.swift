import XCTest
@testable import ClientCore

final class SiriWorkspaceRoutingTests: XCTestCase {
    let paths = ["/projects/autolith", "/projects/autolith-ios", "/other/autolith"]
    func testExplicitReferencesAndNicknames() {
        let config = SiriWorkspaceConfiguration(defaultPath: paths[0], nicknames: [paths[1]: "iOS app"])
        for request in ["In the iOS app workspace, fix the tests", "Fix the tests in iOS app", "In autolith ios, fix the tests"] {
            XCTAssertEqual(SiriWorkspaceRouting.candidates(request: request, paths: paths, configuration: config), [paths[1]])
        }
        XCTAssertEqual(SiriWorkspaceRouting.candidates(request: "Compare autolith-ios with autolith", paths: paths, configuration: config), [])
        XCTAssertEqual(SiriWorkspaceRouting.candidates(request: "In autolith, fix the tests", paths: paths, configuration: config), [paths[0], paths[2]])
        XCTAssertTrue(SiriWorkspaceRouting.hasUnresolvedReference("In the missing workspace, investigate tests"))
        XCTAssertFalse(SiriWorkspaceRouting.hasUnresolvedReference("Investigate failing tests"))
        XCTAssertFalse(SiriWorkspaceRouting.hasUnresolvedReference("Investigate tests in Rust"))
        XCTAssertEqual(SiriWorkspaceRouting.candidates(request: "In missing workspace, compare tests in iOS app workspace", paths: paths, configuration: config), [])
    }
    func testOrdinaryQuestionTextDoesNotRequireWorkspaceClarification() {
        for request in ["How do lifetimes work in Rust?", "What is broken in the current implementation?", "Explain differences in behavior"] {
            XCTAssertFalse(SiriWorkspaceRouting.hasUnresolvedReference(request))
            XCTAssertEqual(SiriWorkspaceRouting.candidates(request: request, paths: paths, configuration: .init()), [])
        }
        XCTAssertTrue(SiriWorkspaceRouting.hasUnresolvedReference("Investigate tests in the missing workspace"))
    }
    func testDuplicateAliasesRemainAmbiguous() {
        let config = SiriWorkspaceConfiguration(nicknames: [paths[0]: "backend", paths[1]: "backend"])
        XCTAssertEqual(SiriWorkspaceRouting.candidates(request: "In backend, investigate", paths: paths, configuration: config), Array(paths.prefix(2)))
    }
    func testPreferencesAreScopedToComputerAndPersist() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let config = SiriWorkspaceConfiguration(defaultPath: paths[0], nicknames: [paths[0]: "backend"])
        try config.save(host: "https://computer-a", defaults: defaults)
        XCTAssertEqual(SiriWorkspaceConfiguration.load(host: "https://computer-a", defaults: defaults), config)
        XCTAssertNil(SiriWorkspaceConfiguration.load(host: "https://computer-b", defaults: defaults).defaultPath)
    }
}
