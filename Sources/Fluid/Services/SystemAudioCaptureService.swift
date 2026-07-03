import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Errors surfaced while capturing system audio via ScreenCaptureKit.
enum SystemAudioCaptureError: LocalizedError {
    case permissionDenied
    case noDisplayAvailable
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "未获得「屏幕录制」权限，无法采集系统声音。请在「系统设置 → 隐私与安全性 → 屏幕录制」中授权 FluidVoice。"
        case .noDisplayAvailable:
            return "找不到可用的显示器来采集系统音频。"
        case let .streamFailed(message):
            return "系统音频采集失败：\(message)"
        }
    }
}

/// Captures system (loopback) audio using ScreenCaptureKit and emits 16 kHz mono Float32 samples.
///
/// ScreenCaptureKit requires a video-producing stream, so a minimal 2×2 / 1 fps configuration is
/// used purely to satisfy the API — only the audio output is consumed. The current process's own
/// audio is excluded to avoid feedback loops.
final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the audio sample queue with newly captured 16 kHz mono samples.
    var onSamples: (([Float]) -> Void)?
    /// Called on the main queue if the stream stops unexpectedly with an error.
    var onStreamError: ((Error) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.fluidapp.systemaudio.samples")
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    private let targetSampleRate: Double = 16_000

    /// Starts capturing system audio. Throws `SystemAudioCaptureError` if permission is missing.
    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            DebugLogger.shared.error("SCShareableContent failed: \(error)", source: "SystemAudioCaptureService")
            throw SystemAudioCaptureError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(self.targetSampleRate)
        config.channelCount = 1
        // Minimal video footprint — required by the API but unused.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
            try await stream.startCapture()
        } catch {
            DebugLogger.shared.error("SCStream start failed: \(error)", source: "SystemAudioCaptureService")
            throw SystemAudioCaptureError.streamFailed(error.localizedDescription)
        }
        self.stream = stream
        DebugLogger.shared.info("System audio capture started", source: "SystemAudioCaptureService")
    }

    /// Stops capturing system audio.
    func stop() async {
        guard let stream = self.stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            DebugLogger.shared.warning("SCStream stop error: \(error)", source: "SystemAudioCaptureService")
        }
        self.converter = nil
        self.converterSourceFormat = nil
        DebugLogger.shared.info("System audio capture stopped", source: "SystemAudioCaptureService")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let samples = self.convertToMono16k(sampleBuffer)
        guard !samples.isEmpty else { return }
        self.onSamples?(samples)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DebugLogger.shared.error("SCStream stopped with error: \(error)", source: "SystemAudioCaptureService")
        DispatchQueue.main.async { [weak self] in
            self?.onStreamError?(SystemAudioCaptureError.streamFailed(error.localizedDescription))
        }
    }

    // MARK: - Conversion

    private func convertToMono16k(_ sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let sourceFormat = AVAudioFormat(streamDescription: asbd)
        else {
            return []
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(numSamples))
        else {
            return []
        }
        sourceBuffer.frameLength = AVAudioFrameCount(numSamples)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            DebugLogger.shared.warning("CMSampleBufferCopyPCMDataIntoAudioBufferList failed: \(status)", source: "SystemAudioCaptureService")
            return []
        }

        // Fast path: already 16 kHz mono Float32.
        if sourceFormat.sampleRate == self.targetSampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let channelData = sourceBuffer.floatChannelData
        {
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(sourceBuffer.frameLength)))
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return []
        }

        if self.converter == nil || self.converterSourceFormat != sourceFormat {
            self.converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            self.converterSourceFormat = sourceFormat
        }
        guard let converter = self.converter else { return [] }

        let ratio = self.targetSampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return []
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let error = error {
            DebugLogger.shared.warning("System audio conversion error: \(error)", source: "SystemAudioCaptureService")
            return []
        }

        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
