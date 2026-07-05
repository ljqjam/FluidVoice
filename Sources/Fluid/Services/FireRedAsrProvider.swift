import AVFoundation
import Foundation

#if arch(arm64)
import SherpaOnnx

/// FireRedASR (AED, int8) via the sherpa-onnx offline recognizer. SOTA Mandarin accuracy; used as the
/// live-meeting two-pass refinement transcriber (replaces Cohere). AED tolerates ≤60s inputs, so the
/// full-session recording is VAD-segmented (≤20s utterances) before decoding, then the segment texts
/// are joined into the refined transcript.
final class FireRedAsrProvider: TranscriptionProvider {
    let name = "FireRedASR (中文)"

    var isAvailable: Bool { true }
    private(set) var isReady: Bool = false
    var prefersNativeFileTranscription: Bool { true }

    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let sampleRate = 16_000
    /// Hard cap per decode as an AED safety net when VAD is unavailable (well under the 60s limit).
    private let maxChunkSeconds: Double = 40

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }
        guard let directory = FireRedAsrModelLocator.directory,
              let encoderURL = FireRedAsrModelLocator.encoderURL,
              let decoderURL = FireRedAsrModelLocator.decoderURL,
              let tokensURL = FireRedAsrModelLocator.tokensURL
        else {
            throw Self.makeError("无法解析 FireRedASR 模型缓存目录。")
        }

        let relay = ModelPreparationProgressRelay(progressHandler)
        let downloader = HuggingFaceModelDownloader(
            owner: FireRedAsrModelLocator.repoOwner,
            repo: FireRedAsrModelLocator.repoName,
            requiredItems: [
                .init(path: FireRedAsrModelLocator.encoderFileName, isDirectory: false),
                .init(path: FireRedAsrModelLocator.decoderFileName, isDirectory: false),
                .init(path: FireRedAsrModelLocator.tokensFileName, isDirectory: false),
            ]
        )
        try await downloader.ensureModelsPresent(at: directory) { progress, _ in
            relay.report(progress)
        }
        try Task.checkCancellation()

        let fireRed = sherpaOnnxOfflineFireRedAsrModelConfig(
            encoder: encoderURL.path,
            decoder: decoderURL.path
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensURL.path,
            numThreads: 2,
            provider: "cpu",
            fireRedAsr: fireRed
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: modelConfig
        )
        self.recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        self.isReady = true
        DebugLogger.shared.info("FireRedASR: provider ready", source: "FireRedAsrProvider")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let text = try self.decodeChunked(samples).joined(separator: "\n")
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        let samples = try Self.loadMono16kSamples(from: fileURL)
        try Task.checkCancellation()
        let segments = await self.segmentByVAD(samples)
        var lines: [String] = []
        for segment in segments {
            try Task.checkCancellation()
            let text = try self.decodeChunked(segment).joined(separator: "\n")
            if !text.isEmpty { lines.append(text) }
        }
        return ASRTranscriptionResult(text: lines.joined(separator: "\n"), confidence: 1.0)
    }

    /// Decodes a buffer, splitting into ≤`maxChunkSeconds` windows so AED never exceeds its limit.
    private func decodeChunked(_ samples: [Float]) throws -> [String] {
        guard let recognizer = self.recognizer else {
            throw Self.makeError("FireRedASR 模型尚未初始化。")
        }
        let maxChunk = Int(Double(self.sampleRate) * self.maxChunkSeconds)
        guard samples.count > maxChunk else {
            let text = recognizer.decode(samples: samples, sampleRate: self.sampleRate)
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [text]
        }
        var results: [String] = []
        var index = 0
        while index < samples.count {
            let end = min(index + maxChunk, samples.count)
            let chunk = Array(samples[index..<end])
            let text = recognizer.decode(samples: chunk, sampleRate: self.sampleRate)
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { results.append(text) }
            index = end
        }
        return results
    }

    /// Splits the full recording into speech utterances (≤20s each). Falls back to fixed-window
    /// chunking when the Silero VAD model is unavailable.
    private func segmentByVAD(_ samples: [Float]) async -> [[Float]] {
        guard let segmenter = await SileroVADSegmenter.makeDefault() else {
            return Self.fixedWindows(samples, windowSamples: Int(Double(self.sampleRate) * self.maxChunkSeconds))
        }
        var segments: [[Float]] = []
        let blockSize = self.sampleRate // feed ~1s blocks
        var index = 0
        while index < samples.count {
            let end = min(index + blockSize, samples.count)
            segments.append(contentsOf: segmenter.acceptWaveform(Array(samples[index..<end])).map(\.samples))
            index = end
        }
        segments.append(contentsOf: segmenter.flush().map(\.samples))
        return segments.isEmpty ? [samples] : segments
    }

    private static func fixedWindows(_ samples: [Float], windowSamples: Int) -> [[Float]] {
        guard windowSamples > 0, samples.count > windowSamples else { return [samples] }
        var windows: [[Float]] = []
        var index = 0
        while index < samples.count {
            let end = min(index + windowSamples, samples.count)
            windows.append(Array(samples[index..<end]))
            index = end
        }
        return windows
    }

    /// Reads an audio file into 16 kHz mono Float32 samples via the shared meeting resampler.
    private static func loadMono16kSamples(from fileURL: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer)
        return LiveMeetingTranscriptionService.resampleToMono16k(buffer)
    }

    func modelsExistOnDisk() -> Bool {
        FireRedAsrModelLocator.modelsExist()
    }

    func clearCache() async throws {
        guard let directory = FireRedAsrModelLocator.directory else { return }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        self.recognizer = nil
        self.isReady = false
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "FireRedAsrProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

#else

final class FireRedAsrProvider: TranscriptionProvider {
    let name = "FireRedASR (中文)"
    let isAvailable = false
    let isReady = false

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        throw NSError(
            domain: "FireRedAsrProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FireRedASR 仅支持 Apple Silicon Mac。"]
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "FireRedAsrProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FireRedASR 仅支持 Apple Silicon Mac。"]
        )
    }
}
#endif
