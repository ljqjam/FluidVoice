import XCTest
@testable import FluidVoice_Debug

final class SenseVoiceTextSanitizerTests: XCTestCase {
    func testStripsRichTokens() {
        XCTAssertEqual(
            SenseVoiceTextSanitizer.clean("<|zh|><|NEUTRAL|><|Speech|><|woitn|>你好，世界。"),
            "你好，世界。"
        )
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(SenseVoiceTextSanitizer.clean("hello world"), "hello world")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(SenseVoiceTextSanitizer.clean("  <|en|> hi there \n"), "hi there")
    }

    func testTokensInMiddleRemoved() {
        XCTAssertEqual(SenseVoiceTextSanitizer.clean("前半句<|zh|>后半句"), "前半句后半句")
    }
}
