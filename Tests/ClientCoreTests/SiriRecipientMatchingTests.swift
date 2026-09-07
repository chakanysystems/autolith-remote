import XCTest
@testable import ClientCore

final class SiriRecipientMatchingTests: XCTestCase {
    private let candidates = [
        SiriRecipientMatching.Candidate(id: "mac#one", name: "Autolith: Fix issue"),
        SiriRecipientMatching.Candidate(id: "mac#two", name: "Autolith: Fix issue"),
        SiriRecipientMatching.Candidate(id: "mac", name: "Autolith")
    ]
    func testIdentitySurvivesRenameAndNeverFallsBackAcrossHosts() {
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: "mac#two", name: "Old title", candidates: candidates), ["mac#two"])
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: "other#two", name: "Autolith: Fix issue", candidates: candidates).isEmpty)
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: "mac#deleted", name: "Autolith", candidates: candidates).isEmpty)
    }
    func testDuplicateNamesRemainAmbiguousAndUnknownNamesAreNotGuessed() {
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: nil, name: "autolith: fix issue", candidates: candidates), ["mac#one", "mac#two"])
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: nil, name: " Autolith ", candidates: candidates), ["mac"])
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: nil, name: "Alice", candidates: candidates).isEmpty)
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: nil, name: "", candidates: candidates).isEmpty)
    }
    func testSiriSynthesizedIdentityCanResolveAnExactName() {
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: UUID().uuidString, name: "Autolith", candidates: candidates), ["mac"])
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: UUID().uuidString, name: "Autolith: Fix issue", candidates: candidates), ["mac#one", "mac#two"])
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: UUID().uuidString, name: "Someone else", candidates: candidates).isEmpty)
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: "https://other-mac/#session:one", name: "Autolith", candidates: candidates).isEmpty)
    }
}
