import XCTest
@testable import FluidVoice_Debug

final class LiveMeetingRefinementTests: XCTestCase {
    func testShouldAttemptOnlyWhenCohereAndAudioPresent() {
        XCTAssertTrue(LiveMeetingRefinement.shouldAttempt(cohereInstalled: true, audioFileExists: true))
        XCTAssertFalse(LiveMeetingRefinement.shouldAttempt(cohereInstalled: false, audioFileExists: true))
        XCTAssertFalse(LiveMeetingRefinement.shouldAttempt(cohereInstalled: true, audioFileExists: false))
        XCTAssertFalse(LiveMeetingRefinement.shouldAttempt(cohereInstalled: false, audioFileExists: false))
    }

    func testRefinedTextReplacesLive() {
        XCTAssertEqual(LiveMeetingRefinement.finalTranscript(live: "live 稿", refined: "精修稿"), "精修稿")
    }

    func testEmptyOrNilRefinedFallsBackToLive() {
        XCTAssertEqual(LiveMeetingRefinement.finalTranscript(live: "live 稿", refined: nil), "live 稿")
        XCTAssertEqual(LiveMeetingRefinement.finalTranscript(live: "live 稿", refined: ""), "live 稿")
        XCTAssertEqual(LiveMeetingRefinement.finalTranscript(live: "live 稿", refined: "  \n"), "live 稿")
    }
}
