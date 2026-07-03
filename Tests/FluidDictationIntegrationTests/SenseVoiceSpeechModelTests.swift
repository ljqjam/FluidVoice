import XCTest
@testable import FluidVoice_Debug

final class SenseVoiceSpeechModelTests: XCTestCase {
    func testSenseVoiceSmallMetadata() {
        let model = SettingsStore.SpeechModel.senseVoiceSmall
        XCTAssertEqual(model.rawValue, "sensevoice-small")
        XCTAssertEqual(model.displayName, "SenseVoice Small")
        XCTAssertTrue(model.requiresAppleSilicon)
        XCTAssertFalse(model.isWhisperModel)
        XCTAssertFalse(model.requiresMacOS15)
        XCTAssertFalse(model.requiresMacOS26)
        XCTAssertEqual(model.provider, .alibaba)
        XCTAssertEqual(model.brandName, "Alibaba")
        XCTAssertNil(model.whisperModelFile)
        XCTAssertTrue(model.supportsStreaming)
        XCTAssertGreaterThan(model.expectedDownloadBytes, 200_000_000)
    }

    func testSenseVoiceSmallAvailableOnAppleSilicon() {
        #if arch(arm64)
        XCTAssertTrue(SettingsStore.SpeechModel.availableModels.contains(.senseVoiceSmall))
        #else
        XCTAssertFalse(SettingsStore.SpeechModel.availableModels.contains(.senseVoiceSmall))
        #endif
    }
}
