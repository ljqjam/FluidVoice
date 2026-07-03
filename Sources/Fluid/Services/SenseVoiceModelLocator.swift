import Foundation

/// Locates the on-disk cache for the SenseVoice-Small sherpa-onnx artifacts.
/// Kept free of sherpa-onnx imports so SettingsStore can query install state on any architecture.
enum SenseVoiceModelLocator {
    static let modelFileName = "model.int8.onnx"
    static let tokensFileName = "tokens.txt"

    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sensevoice-small-onnx", isDirectory: true)
    }

    static var modelURL: URL? { self.directory?.appendingPathComponent(self.modelFileName) }
    static var tokensURL: URL? { self.directory?.appendingPathComponent(self.tokensFileName) }

    static func modelsExist() -> Bool {
        guard let modelURL = self.modelURL, let tokensURL = self.tokensURL else { return false }
        return HuggingFaceModelDownloader.artifactIsComplete(at: modelURL, isDirectory: false)
            && HuggingFaceModelDownloader.artifactIsComplete(at: tokensURL, isDirectory: false)
    }
}
