import Foundation

/// A provider that supports true-streaming partial previews on a dedicated decoding stream:
/// state is kept across calls so partials grow monotonically instead of being re-decoded from
/// scratch each tick. Callers must serialize these with any other decode on the same model.
protocol IncrementalStreamingPreview: AnyObject {
    /// Start a fresh preview stream for a new utterance (clears prior decoding state).
    func resetPreviewStream()
    /// Feed only the newly captured samples; returns the cumulative partial text so far.
    func feedPreviewStream(_ samples: [Float]) -> String
    /// Release the preview stream at session end.
    func releasePreviewStream()
}

#if arch(arm64)
import SherpaOnnx

/// streaming-zipformer-zh (xlarge, int8) via the sherpa-onnx online recognizer.
/// Chinese-optimized true-streaming transducer; replaces SenseVoice as the live-meeting
/// utterance/preview transcriber. Decodes a supplied buffer by feeding it into a fresh online
/// stream, flushing with trailing silence, then draining the decode loop for the final result.
final class StreamingZipformerProvider: TranscriptionProvider, IncrementalStreamingPreview {
    let name = "Streaming Zipformer (中文)"

    var isAvailable: Bool { true }
    private(set) var isReady: Bool = false
    private var recognizer: SherpaOnnxRecognizer?
    private let sampleRate = 16_000
    /// Preview decodes only the recent tail so xlarge (RTF≈0.46) stays responsive per throttle tick.
    private let streamingPreviewMaxSeconds: Double = 6
    /// Trailing zero-padding appended before `inputFinished` so the encoder flushes the last frames.
    private let flushPaddingSeconds: Double = 0.5

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }
        guard let directory = StreamingZipformerModelLocator.directory,
              let encoderURL = StreamingZipformerModelLocator.encoderURL,
              let decoderURL = StreamingZipformerModelLocator.decoderURL,
              let joinerURL = StreamingZipformerModelLocator.joinerURL,
              let tokensURL = StreamingZipformerModelLocator.tokensURL
        else {
            throw Self.makeError("无法解析 streaming-zipformer 模型缓存目录。")
        }

        let relay = ModelPreparationProgressRelay(progressHandler)
        let downloader = HuggingFaceModelDownloader(
            owner: StreamingZipformerModelLocator.repoOwner,
            repo: StreamingZipformerModelLocator.repoName,
            requiredItems: [
                .init(path: StreamingZipformerModelLocator.encoderFileName, isDirectory: false),
                .init(path: StreamingZipformerModelLocator.decoderFileName, isDirectory: false),
                .init(path: StreamingZipformerModelLocator.joinerFileName, isDirectory: false),
                .init(path: StreamingZipformerModelLocator.tokensFileName, isDirectory: false),
            ]
        )
        try await downloader.ensureModelsPresent(at: directory) { progress, _ in
            relay.report(progress)
        }
        try Task.checkCancellation()

        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: encoderURL.path,
            decoder: decoderURL.path,
            joiner: joinerURL.path
        )
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: tokensURL.path,
            transducer: transducer,
            numThreads: 2,
            provider: "cpu",
            modelingUnit: "cjkchar"
        )
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: modelConfig
        )
        self.recognizer = SherpaOnnxRecognizer(config: &config)
        self.isReady = true
        DebugLogger.shared.info("StreamingZipformer: provider ready", source: "StreamingZipformerProvider")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let maxPreview = Int(Double(self.sampleRate) * self.streamingPreviewMaxSeconds)
        let preview = samples.count > maxPreview ? Array(samples.suffix(maxPreview)) : samples
        return try await self.decodeBuffer(preview)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.decodeBuffer(samples)
    }

    // MARK: - Incremental streaming preview

    func resetPreviewStream() {
        self.recognizer?.resetPreviewStream()
    }

    func feedPreviewStream(_ samples: [Float]) -> String {
        guard let recognizer = self.recognizer else { return "" }
        return recognizer.feedPreviewStream(samples: samples, sampleRate: self.sampleRate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func releasePreviewStream() {
        self.recognizer?.releasePreviewStream()
    }

    private func decodeBuffer(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let recognizer = self.recognizer else {
            throw Self.makeError("streaming-zipformer 模型尚未初始化。")
        }
        let startedAt = Date()
        // Clear any state from the previous decode so buffers don't bleed across utterances.
        recognizer.reset()
        recognizer.acceptWaveform(samples: samples, sampleRate: self.sampleRate)
        let padding = [Float](repeating: 0, count: Int(Double(self.sampleRate) * self.flushPaddingSeconds))
        recognizer.acceptWaveform(samples: padding, sampleRate: self.sampleRate)
        recognizer.inputFinished()
        while recognizer.isReady() {
            recognizer.decode()
        }
        let text = recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioSeconds = Double(samples.count) / Double(self.sampleRate)
        let elapsed = Date().timeIntervalSince(startedAt)
        DebugLogger.shared.debug(
            "StreamingZipformer: decoded \(String(format: "%.2f", audioSeconds))s in \(String(format: "%.2f", elapsed))s",
            source: "StreamingZipformerProvider"
        )
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }

    func modelsExistOnDisk() -> Bool {
        StreamingZipformerModelLocator.modelsExist()
    }

    func clearCache() async throws {
        guard let directory = StreamingZipformerModelLocator.directory else { return }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        self.recognizer = nil
        self.isReady = false
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "StreamingZipformerProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

#else

final class StreamingZipformerProvider: TranscriptionProvider, IncrementalStreamingPreview {
    let name = "Streaming Zipformer (中文)"
    let isAvailable = false
    let isReady = false

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        throw NSError(
            domain: "StreamingZipformerProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "streaming-zipformer 仅支持 Apple Silicon Mac。"]
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "StreamingZipformerProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "streaming-zipformer 仅支持 Apple Silicon Mac。"]
        )
    }

    func resetPreviewStream() {}
    func feedPreviewStream(_ samples: [Float]) -> String { "" }
    func releasePreviewStream() {}
}
#endif
