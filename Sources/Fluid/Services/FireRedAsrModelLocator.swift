import Foundation

/// Locates the on-disk cache for the FireRedASR (AED, int8) sherpa-onnx artifacts.
/// Kept free of sherpa-onnx imports so SettingsStore/UI can query install state on any architecture.
///
/// Defaults to the confirmed v1 large repo (CER 3.05/3.18 on public Mandarin benchmarks). To move to
/// FireRedASR2-AED, update `repoName` and the encoder/decoder file names once its HF mirror is public.
enum FireRedAsrModelLocator {
    static let repoOwner = "csukuangfj"
    static let repoName = "sherpa-onnx-fire-red-asr-large-zh_en-2025-02-16"

    static let encoderFileName = "encoder.int8.onnx"
    static let decoderFileName = "decoder.int8.onnx"
    static let tokensFileName = "tokens.txt"

    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("fire-red-asr-large-onnx", isDirectory: true)
    }

    static var encoderURL: URL? { self.directory?.appendingPathComponent(self.encoderFileName) }
    static var decoderURL: URL? { self.directory?.appendingPathComponent(self.decoderFileName) }
    static var tokensURL: URL? { self.directory?.appendingPathComponent(self.tokensFileName) }

    static func modelsExist() -> Bool {
        guard let encoderURL, let decoderURL, let tokensURL else { return false }
        return [encoderURL, decoderURL, tokensURL].allSatisfy {
            HuggingFaceModelDownloader.artifactIsComplete(at: $0, isDirectory: false)
        }
    }
}
