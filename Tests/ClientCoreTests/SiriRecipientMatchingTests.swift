import XCTest
@testable import ClientCore

final class SiriRecipientMatchingTests: XCTestCase {
    private let candidates = [
        SiriRecipientMatching.Candidate(id: "computer#one", name: "Autolith: Fix issue"),
        SiriRecipientMatching.Candidate(id: "computer#two", name: "Autolith: Fix issue"),
        SiriRecipientMatching.Candidate(id: "computer", name: "Autolith")
    ]
    func testIdentitySurvivesRenameAndNeverFallsBackAcrossHosts() {
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: "computer#two", name: "Old title", candidates: candidates), ["computer#two"])
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: "other#two", name: "Autolith: Fix issue", candidates: candidates).isEmpty)
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: "computer#deleted", name: "Autolith", candidates: candidates).isEmpty)
    }
    func testDuplicateNamesRemainAmbiguousAndUnknownNamesAreNotGuessed() {
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: nil, name: "autolith: fix issue", candidates: candidates), ["computer#one", "computer#two"])
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: nil, name: " Autolith ", candidates: candidates), ["computer"])
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: nil, name: "Alice", candidates: candidates).isEmpty)
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: nil, name: "", candidates: candidates).isEmpty)
    }
    func testSiriSynthesizedIdentityCanResolveAnExactName() {
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: UUID().uuidString, name: "Autolith", candidates: candidates), ["computer"])
        XCTAssertEqual(SiriRecipientMatching.identifiers(applicationID: UUID().uuidString, name: "Autolith: Fix issue", candidates: candidates), ["computer#one", "computer#two"])
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: UUID().uuidString, name: "Someone else", candidates: candidates).isEmpty)
        XCTAssertTrue(SiriRecipientMatching.identifiers(applicationID: "https://other-computer/#session:one", name: "Autolith", candidates: candidates).isEmpty)
    }
}
