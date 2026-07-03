import AVFoundation
import XCTest
@testable import FluidVoice_Debug

final class MeetingAudioFileWriterTests: XCTestCase {
    func testWritesSamplesReadableAsWav() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioFileWriterTests-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MeetingAudioFileWriter(url: url)
        let chunk = [Float](repeating: 0.25, count: 8000)
        try writer.append(chunk)
        try writer.append(chunk)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 16000)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
    }

    func testEmptyAppendIsNoop() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioFileWriterTests-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MeetingAudioFileWriter(url: url)
        try writer.append([])
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 0)
    }
}
