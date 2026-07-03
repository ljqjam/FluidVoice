import Foundation

/// Strips SenseVoice rich-transcription tokens like <|zh|>, <|NEUTRAL|>, <|Speech|>.
/// Kept outside the arch guard so it is unit-testable on any architecture.
enum SenseVoiceTextSanitizer {
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if arch(arm64)
import SherpaOnnx

/// SenseVoice-Small via the sherpa-onnx runtime (CPU, non-autoregressive).
/// Optimized for Chinese/Cantonese; also covers English, Japanese, Korean.
final class SenseVoiceProvider: TranscriptionProvider {
    let name = "SenseVoice"

    var isAvailable: Bool { true }
    private(set) var isReady: Bool = false
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let streamingPreviewMaxSeconds: Double = 12
    private let sampleRate = 16_000
    /// SenseVoice language hint. Per-utterance auto-detection on short VAD segments is unreliable,
    /// so default to Chinese (the primary live-meeting language) for markedly better accuracy.
    private let language: String

    init(language: String = "zh") {
        self.language = language
    }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }
        guard let directory = SenseVoiceModelLocator.directory,
              let modelURL = SenseVoiceModelLocator.modelURL,
              let tokensURL = SenseVoiceModelLocator.tokensURL
        else {
            throw Self.makeError("无法解析 SenseVoice 模型缓存目录。")
        }

        let relay = ModelPreparationProgressRelay(progressHandler)
        let downloader = HuggingFaceModelDownloader(
            owner: "csukuangfj",
            repo: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
            requiredItems: [
                .init(path: SenseVoiceModelLocator.modelFileName, isDirectory: false),
                .init(path: SenseVoiceModelLocator.tokensFileName, isDirectory: false),
            ]
        )
        try await downloader.ensureModelsPresent(at: directory) { progress, _ in
            relay.report(progress)
        }
        try Task.checkCancellation()

        let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelURL.path,
            language: self.language,
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensURL.path,
            numThreads: 2,
            provider: "cpu",
            senseVoice: senseVoiceConfig
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: modelConfig
        )
        self.recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        self.isReady = true
        DebugLogger.shared.info("SenseVoice: provider ready", source: "SenseVoiceProvider")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let maxPreview = Int(Double(self.sampleRate) * self.streamingPreviewMaxSeconds)
        let preview = samples.count > maxPreview ? Array(samples.suffix(maxPreview)) : samples
        return try await self.transcribeFinal(preview)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let recognizer = self.recognizer else {
            throw Self.makeError("SenseVoice 模型尚未初始化。")
        }
        let startedAt = Date()
        let result = recognizer.decode(samples: samples, sampleRate: self.sampleRate)
        let text = SenseVoiceTextSanitizer.clean(result.text)
        let audioSeconds = Double(samples.count) / Double(self.sampleRate)
        let elapsed = Date().timeIntervalSince(startedAt)
        DebugLogger.shared.debug(
            "SenseVoice: decoded \(String(format: "%.2f", audioSeconds))s in \(String(format: "%.2f", elapsed))s",
            source: "SenseVoiceProvider"
        )
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }

    func modelsExistOnDisk() -> Bool {
        SenseVoiceModelLocator.modelsExist()
    }

    func clearCache() async throws {
        guard let directory = SenseVoiceModelLocator.directory else { return }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        self.recognizer = nil
        self.isReady = false
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "SenseVoiceProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

#else

final class SenseVoiceProvider: TranscriptionProvider {
    let name = "SenseVoice"
    let isAvailable = false
    let isReady = false

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        throw NSError(
            domain: "SenseVoiceProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "SenseVoice 仅支持 Apple Silicon Mac。"]
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "SenseVoiceProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "SenseVoice 仅支持 Apple Silicon Mac。"]
        )
    }
}
#endif
