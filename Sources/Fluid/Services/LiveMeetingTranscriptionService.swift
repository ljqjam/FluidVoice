import AVFoundation
import Combine
import Foundation

/// Real-time meeting transcription: captures microphone + system audio simultaneously,
/// mixes them into a single 16 kHz mono stream, and transcribes it live using the shared
/// ASR provider. Completed segments are appended to a growing transcript and saved to the
/// file-transcription history when the session stops.
@MainActor
final class LiveMeetingTranscriptionService: ObservableObject {
    @Published var isRunning = false
    @Published var liveTranscript = ""
    @Published var partialText = ""
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var audioLevel: CGFloat = 0
    @Published var elapsedSeconds: TimeInterval = 0

    private let asrService: ASRService
    private let mixer = LiveAudioMixer()
    private let systemCapture = SystemAudioCaptureService()

    private var micEngineStorage: AnyObject?
    private var micEngine: AVAudioEngine {
        if let existing = micEngineStorage as? AVAudioEngine { return existing }
        let created = AVAudioEngine()
        self.micEngineStorage = created
        return created
    }

    private var captureLoopTask: Task<Void, Never>?
    private var transcribeLoopTask: Task<Void, Never>?
    private var startDate: Date?

    // Voice-activity segmentation state.
    private var currentSegment: [Float] = []
    private var inSpeech = false
    private var trailingSilenceSamples = 0
    private var pendingUtterances: [[Float]] = []

    // Silero VAD (nil → RMS fallback), full-session recording, and live-path provider override.
    private var vadSegmenter: SileroVADSegmenter?
    private var audioFileWriter: MeetingAudioFileWriter?
    private var liveUtteranceProvider: TranscriptionProvider?

    // Live partial preview: decode the in-progress (not-yet-finalized) speech buffer with the fast
    // live provider so text appears while the user is still speaking, before the utterance closes.
    private var previewBuffer: [Float] = []
    private var previewToken = 0
    private var isPreviewing = false
    private var lastPreviewAt = Date.distantPast
    private let previewThrottleSeconds: TimeInterval = 0.6
    private let previewMaxSeconds: Double = 12
    private let previewMinSeconds: Double = 0.3

    private let sampleRate: Double = 16_000
    private let captureTickSeconds: TimeInterval = 0.15
    private let speechRMSThreshold: Float = 0.008
    private let endOfUtteranceSeconds: TimeInterval = 0.8
    private let maxSegmentSeconds: TimeInterval = 20
    private let minUtteranceSeconds: TimeInterval = 0.4
    private let trailingSilenceKeepSeconds: TimeInterval = 0.2

    init(asrService: ASRService) {
        self.asrService = asrService
    }

    /// Safety net: if the owning view is discarded without calling `stop()`, cancel the loops
    /// and tear down capture so the mic engine, ScreenCaptureKit stream, and temp wav don't leak.
    /// `deinit` is nonisolated, so teardown of the capture objects hops to a detached task;
    /// `Task.cancel()` itself is safe to call from here. Mirrors the teardown in `stop()` and
    /// is a no-op when `stop()` already ran.
    deinit {
        self.captureLoopTask?.cancel()
        self.transcribeLoopTask?.cancel()

        let engine = self.micEngineStorage as? AVAudioEngine
        let systemCapture = self.systemCapture
        let recordingURL = self.audioFileWriter?.url
        Task.detached {
            if let engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            await systemCapture.stop()
            if let recordingURL {
                try? FileManager.default.removeItem(at: recordingURL)
            }
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !self.isRunning else { return }

        guard !self.asrService.isRunning else {
            self.errorMessage = "语音听写正在进行中，请先停止听写再开始实时会议转录。"
            return
        }

        self.errorMessage = nil
        self.status = "正在准备模型…"
        self.liveTranscript = ""
        self.partialText = ""
        self.currentSegment = []
        self.inSpeech = false
        self.trailingSilenceSamples = 0
        self.pendingUtterances = []
        self.vadSegmenter = nil
        self.audioFileWriter = nil
        self.liveUtteranceProvider = nil
        self.previewBuffer = []
        self.isPreviewing = false
        self.lastPreviewAt = .distantPast
        self.elapsedSeconds = 0
        self.mixer.reset()

        do {
            try await self.asrService.ensureAsrReady()
        } catch {
            self.status = ""
            self.errorMessage = "模型加载失败：\(error.localizedDescription)"
            return
        }

        guard self.asrService.fileTranscriptionProvider.isReady else {
            self.status = ""
            self.errorMessage = "转写引擎尚未就绪。"
            return
        }

        // Microphone.
        do {
            try self.requestMicrophoneIfNeeded()
            try self.startMicrophone()
        } catch {
            self.status = ""
            self.errorMessage = "麦克风启动失败：\(error.localizedDescription)"
            return
        }

        // System audio (ScreenCaptureKit).
        self.systemCapture.onSamples = { [mixer = self.mixer] samples in
            mixer.appendSystem(samples)
        }
        self.systemCapture.onStreamError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error.localizedDescription
            }
        }
        do {
            try await self.systemCapture.start()
        } catch {
            self.stopMicrophone()
            self.status = ""
            self.errorMessage = error.localizedDescription
            return
        }

        // Silero VAD：模型缺失时静默下载（~2MB）；任何失败回退 RMS 分段。
        self.vadSegmenter = await SileroVADSegmenter.makeDefault()
        if self.vadSegmenter == nil {
            DebugLogger.shared.warning("Live meeting: Silero VAD unavailable, falling back to RMS", source: "LiveMeetingTranscriptionService")
        }

        // 整场混音落盘，供 stop 时 Cohere two-pass 精修；写入失败则跳过精修。
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-meeting-\(UUID().uuidString).wav")
        self.audioFileWriter = try? MeetingAudioFileWriter(url: recordingURL)
        if self.audioFileWriter == nil {
            DebugLogger.shared.warning("Live meeting: audio writer init failed, two-pass disabled", source: "LiveMeetingTranscriptionService")
        }

        // 实时路径优先 SenseVoice：已下载即用，与全局听写模型解耦。
        self.liveUtteranceProvider = nil
        if SenseVoiceModelLocator.modelsExist() {
            let senseVoice = SenseVoiceProvider()
            if (try? await senseVoice.prepare(progressHandler: nil)) != nil, senseVoice.isReady {
                self.liveUtteranceProvider = senseVoice
                DebugLogger.shared.info("Live meeting: using SenseVoice for live utterances", source: "LiveMeetingTranscriptionService")
            }
        }

        // Drop the warm-up pre-roll (audio captured while VAD/writer/provider were
        // initializing) so both streams align with `startDate` at t=0; otherwise the
        // wall-clock-paced consumer lags by the backlog and the session tail is lost.
        self.mixer.reset()
        self.startDate = Date()
        self.isRunning = true
        self.status = "正在采集与转写…"
        self.startLoops()
        DebugLogger.shared.info("Live meeting transcription started; provider=\(self.asrService.fileTranscriptionProvider.name)", source: "LiveMeetingTranscriptionService")
    }

    func stop() async {
        guard self.isRunning else { return }
        self.isRunning = false
        self.status = "正在整理转录…"

        self.captureLoopTask?.cancel()
        self.captureLoopTask = nil

        // Invalidate any in-flight preview so a late decode can't overwrite the final transcript.
        self.resetPreview()

        self.stopMicrophone()
        await self.systemCapture.stop()

        // Drain remaining mixed audio through the VAD, then flush any in-progress utterance.
        if let startDate = self.startDate {
            let elapsedSamples = Int(Date().timeIntervalSince(startDate) * self.sampleRate)
            let remaining = self.mixer.pullMixed(elapsedSamples: elapsedSamples)
            self.processVAD(block: remaining)
        }
        if let segmenter = self.vadSegmenter {
            for utterance in segmenter.flush()
                where Double(utterance.count) / self.sampleRate >= self.minUtteranceSeconds
            {
                self.pendingUtterances.append(utterance)
            }
        } else {
            self.flushCurrentUtterance()
        }

        // Let the transcription worker drain the queue, then stop it.
        await self.drainPendingUtterances()
        self.transcribeLoopTask?.cancel()
        self.transcribeLoopTask = nil
        self.partialText = ""

        let duration = self.startDate.map { Date().timeIntervalSince($0) } ?? self.elapsedSeconds
        self.startDate = nil
        self.mixer.reset()
        self.audioLevel = 0
        self.status = ""

        // Two-pass：Cohere 已下载且录音存在 → 全文精修，替换 live 稿。
        let recordingURL = self.audioFileWriter?.url
        self.audioFileWriter = nil
        defer {
            if let recordingURL {
                try? FileManager.default.removeItem(at: recordingURL)
            }
        }

        let liveText = self.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        var refinedText: String?
        let audioFileExists = recordingURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if SettingsStore.shared.liveMeetingRefinementEnabled,
           LiveMeetingRefinement.shouldAttempt(
               cohereInstalled: SettingsStore.SpeechModel.cohereTranscribeSixBit.isInstalled,
               audioFileExists: audioFileExists
           ), let recordingURL {
            self.status = "正在精修转录…"
            do {
                let cohere = ExternalCoreMLTranscriptionProvider(
                    modelOverride: .cohereTranscribeSixBit,
                    languageOverride: .mandarinChinese
                )
                try await cohere.prepare(progressHandler: nil)
                let result = try await self.asrService.runSerializedTranscription {
                    try await cohere.transcribeFile(at: recordingURL)
                }
                refinedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                DebugLogger.shared.warning("Live meeting refinement failed: \(error)", source: "LiveMeetingTranscriptionService")
            }
        }

        let finalText = LiveMeetingRefinement.finalTranscript(live: liveText, refined: refinedText)
        self.liveTranscript = finalText
        self.status = ""

        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let result = TranscriptionResult(
                text: text,
                confidence: 1.0,
                duration: duration,
                processingTime: duration,
                fileName: "实时会议 \(formatter.string(from: Date()))"
            )
            FileTranscriptionHistoryStore.shared.addEntry(result)
            MeetingTranscriptExporter.export(text: text, displayName: result.fileName)
        }
        DebugLogger.shared.info("Live meeting transcription stopped", source: "LiveMeetingTranscriptionService")
    }

    // MARK: - Microphone

    private func requestMicrophoneIfNeeded() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if !granted {
                throw NSError(domain: "LiveMeeting", code: -1, userInfo: [NSLocalizedDescriptionKey: "麦克风权限被拒绝"])
            }
        default:
            throw NSError(domain: "LiveMeeting", code: -2, userInfo: [NSLocalizedDescriptionKey: "麦克风权限未开启"])
        }
    }

    private func startMicrophone() throws {
        let engine = self.micEngine
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "LiveMeeting", code: -3, userInfo: [NSLocalizedDescriptionKey: "麦克风输入格式无效"])
        }

        let mixer = self.mixer
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let samples = LiveMeetingTranscriptionService.resampleToMono16k(buffer)
            if !samples.isEmpty {
                mixer.appendMic(samples)
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        guard let engine = self.micEngineStorage as? AVAudioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Capture + VAD loop (never blocks on transcription)

    private func startLoops() {
        // Both loops re-acquire `self` weakly on every iteration so the service can deallocate
        // (triggering the `deinit` safety net) even if `stop()` is never called.
        self.captureLoopTask = Task { [weak self, tickNanos = UInt64(self.captureTickSeconds * 1_000_000_000)] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: tickNanos)
                if Task.isCancelled { break }
                guard let self else { break }
                self.captureTick()
            }
        }
        self.transcribeLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let didWork = await self.transcribeNextUtteranceIfAvailable()
                if !didWork {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
        }
    }

    private func captureTick() {
        guard self.isRunning, let startDate = self.startDate else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        self.elapsedSeconds = elapsed

        let elapsedSamples = Int(elapsed * self.sampleRate)
        let block = self.mixer.pullMixed(elapsedSamples: elapsedSamples)
        guard !block.isEmpty else { return }

        self.audioLevel = CGFloat(min(1.0, Double(Self.rms(block)) * 12))
        try? self.audioFileWriter?.append(block)
        self.processVAD(block: block)
    }

    /// Voice-activity segmentation: accumulate speech into an utterance, drop inter-utterance
    /// silence, and enqueue a completed utterance when a pause is detected or the cap is reached.
    private func processVAD(block: [Float]) {
        guard !block.isEmpty else { return }

        if let segmenter = self.vadSegmenter {
            let completed = segmenter.acceptWaveform(block)
            for utterance in completed
                where Double(utterance.count) / self.sampleRate >= self.minUtteranceSeconds
            {
                self.pendingUtterances.append(utterance)
            }
            if !completed.isEmpty {
                self.resetPreview()
            } else if segmenter.isSpeechActive {
                self.accumulatePreview(block)
            }
            return
        }

        // RMS fallback（原有逻辑保持不变）
        let isSpeech = Self.rms(block) >= self.speechRMSThreshold

        if isSpeech {
            self.inSpeech = true
            self.currentSegment.append(contentsOf: block)
            self.trailingSilenceSamples = 0
            self.accumulatePreview(block)
        } else if self.inSpeech {
            // Keep a little trailing silence for natural word endings.
            self.currentSegment.append(contentsOf: block)
            self.trailingSilenceSamples += block.count
            if Double(self.trailingSilenceSamples) / self.sampleRate >= self.endOfUtteranceSeconds {
                self.flushCurrentUtterance()
            }
        }
        // else: not in speech and this block is silence → ignore (no padding accumulation).

        if Double(self.currentSegment.count) / self.sampleRate >= self.maxSegmentSeconds {
            self.flushCurrentUtterance()
        }
    }

    /// Trims trailing silence and enqueues the current utterance for transcription if it has speech.
    private func flushCurrentUtterance() {
        defer {
            self.currentSegment = []
            self.inSpeech = false
            self.trailingSilenceSamples = 0
            self.resetPreview()
        }
        guard self.inSpeech else { return }

        let keep = Int(self.trailingSilenceKeepSeconds * self.sampleRate)
        var utterance = self.currentSegment
        if self.trailingSilenceSamples > keep {
            let drop = self.trailingSilenceSamples - keep
            if drop < utterance.count {
                utterance.removeLast(drop)
            }
        }
        guard Double(utterance.count) / self.sampleRate >= self.minUtteranceSeconds else { return }
        self.pendingUtterances.append(utterance)
    }

    // MARK: - Live partial preview

    /// Appends in-progress speech to the preview buffer (capped) and throttles a decode so the
    /// user sees tentative text before the utterance closes. No-op unless a fast live provider
    /// (SenseVoice) is active — the file provider is too slow for per-tick previews.
    private func accumulatePreview(_ block: [Float]) {
        guard self.liveUtteranceProvider != nil else { return }
        self.previewBuffer.append(contentsOf: block)
        let maxCount = Int(self.previewMaxSeconds * self.sampleRate)
        if self.previewBuffer.count > maxCount {
            self.previewBuffer.removeFirst(self.previewBuffer.count - maxCount)
        }
        self.schedulePreviewIfNeeded()
    }

    /// Invalidates the current preview (bumps the token so late decodes are dropped) and clears
    /// the tentative text. Called whenever an utterance finalizes or the session stops.
    private func resetPreview() {
        self.previewToken &+= 1
        self.previewBuffer.removeAll(keepingCapacity: true)
        if !self.partialText.isEmpty {
            self.partialText = ""
        }
    }

    private func schedulePreviewIfNeeded() {
        guard let provider = self.liveUtteranceProvider, !self.isPreviewing else { return }
        guard Date().timeIntervalSince(self.lastPreviewAt) >= self.previewThrottleSeconds else { return }
        guard Double(self.previewBuffer.count) / self.sampleRate >= self.previewMinSeconds else { return }

        self.lastPreviewAt = Date()
        self.isPreviewing = true
        let snapshot = self.previewBuffer
        let token = self.previewToken
        Task { [weak self, provider] in
            await self?.runPreview(snapshot, provider: provider, token: token)
        }
    }

    private func runPreview(_ samples: [Float], provider: TranscriptionProvider, token: Int) async {
        defer { self.isPreviewing = false }
        guard self.isRunning else { return }
        do {
            let result = try await self.asrService.runSerializedTranscription { [provider] in
                try await provider.transcribeStreaming(samples)
            }
            // Drop stale results: the utterance may have finalized (or session stopped) meanwhile.
            guard self.isRunning, token == self.previewToken else { return }
            self.partialText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Preview is best-effort; ignore failures.
        }
    }

    // MARK: - Transcription worker

    private func transcribeNextUtteranceIfAvailable() async -> Bool {
        guard !self.pendingUtterances.isEmpty else { return false }
        let utterance = self.pendingUtterances.removeFirst()
        await self.transcribeAndAppend(utterance)
        return true
    }

    private func drainPendingUtterances() async {
        while !self.pendingUtterances.isEmpty {
            let utterance = self.pendingUtterances.removeFirst()
            await self.transcribeAndAppend(utterance)
        }
    }

    private func transcribeAndAppend(_ utterance: [Float]) async {
        do {
            let provider = self.liveUtteranceProvider ?? self.asrService.fileTranscriptionProvider
            let result = try await self.asrService.runSerializedTranscription { [provider] in
                try await provider.transcribeFinal(utterance)
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if self.liveTranscript.isEmpty {
                self.liveTranscript = text
            } else {
                self.liveTranscript += "\n" + text
            }
        } catch {
            DebugLogger.shared.warning("Live utterance transcription failed: \(error)", source: "LiveMeetingTranscriptionService")
        }
    }

    // MARK: - Audio helpers

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for value in samples {
            sum += value * value
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Converts an arbitrary-format PCM buffer to 16 kHz mono Float32 samples.
    nonisolated static func resampleToMono16k(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let sourceFormat = buffer.format
        let targetSampleRate = 16_000.0

        if sourceFormat.sampleRate == targetSampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let channelData = buffer.floatChannelData
        {
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return []
        }

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
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
            return buffer
        }
        if error != nil { return [] }

        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
