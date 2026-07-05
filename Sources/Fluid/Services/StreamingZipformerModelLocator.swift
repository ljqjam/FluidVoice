import Foundation

/// Locates the on-disk cache for the streaming-zipformer-zh (xlarge, int8) sherpa-onnx artifacts.
/// Kept free of sherpa-onnx imports so SettingsStore/UI can query install state on any architecture.
enum StreamingZipformerModelLocator {
    static let repoOwner = "csukuangfj"
    static let repoName = "sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30"

    static let encoderFileName = "encoder.int8.onnx"
    static let decoderFileName = "decoder.onnx"
    static let joinerFileName = "joiner.int8.onnx"
    static let tokensFileName = "tokens.txt"

    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("streaming-zipformer-zh-xlarge-onnx", isDirectory: true)
    }

    static var encoderURL: URL? { self.directory?.appendingPathComponent(self.encoderFileName) }
    static var decoderURL: URL? { self.directory?.appendingPathComponent(self.decoderFileName) }
    static var joinerURL: URL? { self.directory?.appendingPathComponent(self.joinerFileName) }
    static var tokensURL: URL? { self.directory?.appendingPathComponent(self.tokensFileName) }

    static func modelsExist() -> Bool {
        guard let encoderURL, let decoderURL, let joinerURL, let tokensURL else { return false }
        return [encoderURL, decoderURL, joinerURL, tokensURL].allSatisfy {
            HuggingFaceModelDownloader.artifactIsComplete(at: $0, isDirectory: false)
        }
    }
}
