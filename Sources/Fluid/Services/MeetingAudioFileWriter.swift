import Foundation

/// Incrementally writes a 16 kHz mono Float32 stream into a 16-bit PCM wav file.
/// Used by live meeting transcription to keep the full session audio for two-pass refinement.
final class MeetingAudioFileWriter {
    let url: URL
    private let handle: FileHandle
    private var frameCount: UInt32 = 0

    private static let headerSize: UInt32 = 44
    private static let sampleRate: UInt32 = 16_000
    private static let bitsPerSample: UInt16 = 16
    private static let channels: UInt16 = 1

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(
                domain: "MeetingAudioFileWriter",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法创建录音文件。"]
            )
        }
        self.handle = try FileHandle(forWritingTo: url)
        self.url = url
        // Write placeholder header; will be patched after each append.
        handle.write(Data(count: Int(Self.headerSize)))
        patchHeader()
    }

    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        // Seek to end of current data before writing new samples.
        handle.seekToEndOfFile()
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            var v = int16.littleEndian
            Swift.withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        handle.write(pcm)
        frameCount += UInt32(samples.count)
        patchHeader()
    }

    deinit {
        try? handle.close()
    }

    // MARK: - Private

    private func patchHeader() {
        let byteRate = Self.sampleRate * UInt32(Self.channels) * UInt32(Self.bitsPerSample / 8)
        let blockAlign = Self.channels * (Self.bitsPerSample / 8)
        let dataSize = frameCount * UInt32(Self.channels) * UInt32(Self.bitsPerSample / 8)
        let chunkSize = Self.headerSize - 8 + dataSize

        var header = Data(capacity: Int(Self.headerSize))
        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndian: chunkSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndian: UInt32(16))
        header.append(littleEndian: UInt16(1))
        header.append(littleEndian: Self.channels)
        header.append(littleEndian: Self.sampleRate)
        header.append(littleEndian: byteRate)
        header.append(littleEndian: blockAlign)
        header.append(littleEndian: Self.bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.append(littleEndian: dataSize)

        handle.seek(toFileOffset: 0)
        handle.write(header)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
}
