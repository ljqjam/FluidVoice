import Foundation

#if arch(arm64)
import SherpaOnnx

/// Streaming Silero VAD via sherpa-onnx. Segments a 16 kHz mono stream into speech utterances.
/// Thresholds mirror the previous RMS-based segmentation in LiveMeetingTranscriptionService.
final class SileroVADSegmenter {
    private let vad: SherpaOnnxVoiceActivityDetectorWrapper
    private var pending: [Float] = []
    private static let windowSize = 512
    private static let modelDownloadURL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"

    static var modelURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("silero-vad", isDirectory: true)
            .appendingPathComponent("silero_vad.onnx")
    }

    /// Downloads the ~2 MB VAD model if missing, then builds a segmenter. Returns nil on any failure.
    static func makeDefault() async -> SileroVADSegmenter? {
        guard let modelURL = self.modelURL else { return nil }
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            do {
                guard let remote = URL(string: self.modelDownloadURL) else { return nil }
                let (tempFile, response) = try await URLSession.shared.download(from: remote)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    DebugLogger.shared.warning("SileroVAD: model download failed (bad status)", source: "SileroVADSegmenter")
                    return nil
                }
                try FileManager.default.createDirectory(
                    at: modelURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: modelURL)
                try FileManager.default.moveItem(at: tempFile, to: modelURL)
            } catch {
                DebugLogger.shared.warning("SileroVAD: model download failed: \(error)", source: "SileroVADSegmenter")
                return nil
            }
        }
        return SileroVADSegmenter(modelPath: modelURL.path)
    }

    private init?(modelPath: String) {
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        let silero = sherpaOnnxSileroVadModelConfig(
            model: modelPath,
            threshold: 0.5,
            minSilenceDuration: 0.8,
            minSpeechDuration: 0.4,
            windowSize: Self.windowSize,
            maxSpeechDuration: 20.0
        )
        var config = sherpaOnnxVadModelConfig(sileroVad: silero, sampleRate: 16_000)
        self.vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 60)
        DebugLogger.shared.info("SileroVAD: segmenter ready", source: "SileroVADSegmenter")
    }

    func acceptWaveform(_ block: [Float]) -> [[Float]] {
        self.pending.append(contentsOf: block)
        while self.pending.count >= Self.windowSize {
            self.vad.acceptWaveform(samples: Array(self.pending.prefix(Self.windowSize)))
            self.pending.removeFirst(Self.windowSize)
        }
        return self.drainCompletedSegments()
    }

    func flush() -> [[Float]] {
        if !self.pending.isEmpty {
            self.vad.acceptWaveform(samples: self.pending)
            self.pending = []
        }
        self.vad.flush()
        return self.drainCompletedSegments()
    }

    var isSpeechActive: Bool {
        self.vad.isSpeechDetected()
    }

    private func drainCompletedSegments() -> [[Float]] {
        var segments: [[Float]] = []
        while !self.vad.isEmpty() {
            segments.append(self.vad.front().samples)
            self.vad.pop()
        }
        return segments
    }
}

#else

/// Intel stub: live meeting keeps the RMS fallback path.
final class SileroVADSegmenter {
    static func makeDefault() async -> SileroVADSegmenter? { nil }
    func acceptWaveform(_ block: [Float]) -> [[Float]] { [] }
    func flush() -> [[Float]] { [] }
    var isSpeechActive: Bool { false }
}
#endif
