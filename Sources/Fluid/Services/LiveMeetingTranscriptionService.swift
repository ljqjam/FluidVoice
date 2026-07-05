import AVFoundation
import Combine
import Foundation

/// A single meeting transcript line: one VAD-detected utterance with its start time
/// (seconds from session start) and transcribed text. Lines are the source of truth for
/// the live view, history, and export — each renders as a timestamped block.
struct MeetingTranscriptLine: Identifiable, Equatable {
    let id: UUID
    let startTime: TimeInterval
    var text: String

    init(id: UUID = UUID(), startTime: TimeInterval, text: String) {
        self.id = id
        self.startTime = startTime
        self.text = text
    }
}

/// Real-time meeting transcription: captures microphone + system audio simultaneously,
/// mixes them into a single 16 kHz mono stream, and transcribes it live using the shared
/// ASR provider. Completed utterances become timestamped lines and are saved to the
/// file-transcription history when the session stops.
@MainActor
final class LiveMeetingTranscriptionService: ObservableObject {
    @Published var isRunning = false
    @Published var lines: [MeetingTranscriptLine] = []
    @Published var partialText = ""
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var audioLevel: CGFloat = 0
    @Published var elapsedSeconds: TimeInterval = 0

    /// Full transcript as `[MM:SS] text` lines, used for copy / export / saving.
    var liveTranscript: String {
        self.lines
            .map { "[\(Self.formatTimestamp($0.startTime))] \($0.text)" }
            .joined(separator: "\n")
    }

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

    // A completed utterance awaiting transcription, tagged with its session start time.
    private struct PendingUtterance {
        let startTime: TimeInterval
        let samples: [Float]
    }

    // Voice-activity segmentation state.
    private var currentSegment: [Float] = []
    private var inSpeech = false
    private var trailingSilenceSamples = 0
    private var pendingUtterances: [PendingUtterance] = []

    // Running sample counters used to timestamp utterances (RMS fallback path).
    private var totalSamplesProcessed = 0
    private var currentSegmentStartSample = 0

    // Silero VAD (nil → RMS fallback) and live-path provider override.
    private var vadSegmenter: SileroVADSegmenter?
    private var liveUtteranceProvider: TranscriptionProvider?

    // Per-utterance two-pass refinement: retain each line's audio (only when refinement is
    // enabled and the FireRedASR model is present) so we can re-transcribe it at stop while
    // preserving the line's timestamp and position. Released once refinement finishes.
    private var retainAudioForRefinement = false
    private var refineItems: [(id: UUID, samples: [Float])] = []

    // Live partial preview via a true-streaming decode: newly captured speech is fed incrementally
    // to a dedicated preview stream that keeps its decoding state, so the partial text grows
    // monotonically (stable) instead of being re-decoded from scratch each tick. The committed
    // per-utterance line still comes from `liveUtteranceProvider.transcribeFinal` and is unaffected.
    private var previewStreamProvider: IncrementalStreamingPreview?
    private var previewDelta: [Float] = []
    private var previewNeedsReset = true
    private var previewToken = 0
    private var isPreviewing = false
    private var lastPreviewAt = Date.distantPast
    private let previewThrottleSeconds: TimeInterval = 0.6

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
        Task.detached {
            if let engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            await systemCapture.stop()
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
        self.lines = []
        self.partialText = ""
        self.currentSegment = []
        self.inSpeech = false
        self.trailingSilenceSamples = 0
        self.pendingUtterances = []
        self.totalSamplesProcessed = 0
        self.currentSegmentStartSample = 0
        self.vadSegmenter = nil
        self.liveUtteranceProvider = nil
        self.previewStreamProvider = nil
        self.refineItems = []
        self.retainAudioForRefinement = false
        self.previewDelta = []
        self.previewNeedsReset = true
        self.isPreviewing = false
        self.lastPreviewAt = .distantPast
        self.elapsedSeconds = 0
        self.mixer.reset()

        // 实时会议使用独立中文模型，与全局听写引擎解耦。按所选实时引擎校验必需模型是否已下载。
        let engineMode = SettingsStore.shared.liveMeetingEngineMode
        switch engineMode {
        case .streaming:
            guard StreamingZipformerModelLocator.modelsExist() else {
                self.status = ""
                self.errorMessage = "请先在「设置 › 语音识别 › 实时会议模型」中下载 streaming-zipformer（中文）模型。"
                return
            }
        case .highQuality:
            guard FireRedAsrModelLocator.modelsExist() else {
                self.status = ""
                self.errorMessage = "请先在「设置 › 语音识别 › 实时会议模型」中下载 FireRedASR（中文）模型。"
                return
            }
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

        // 实时引擎：按模式选择。
        // - streaming：streaming-zipformer 逐字流式出字；逐句音频保留 7 天，供结束后在历史记录中按需 FireRedASR 精修。
        // - highQuality：FireRedASR 逐句准实时，首遍即最终质量，无流式预览、无精修。
        self.liveUtteranceProvider = nil
        self.previewStreamProvider = nil
        self.retainAudioForRefinement = false

        switch engineMode {
        case .streaming:
            // Always retain per-utterance audio for streaming sessions so the user can trigger
            // on-demand FireRedASR refinement from the history list later (kept for 7 days). The
            // FireRedASR model isn't required now — it may be downloaded within the retention window.
            self.retainAudioForRefinement = true
            let zipformer = StreamingZipformerProvider()
            do {
                try await zipformer.prepare(progressHandler: nil)
                self.liveUtteranceProvider = zipformer
                self.previewStreamProvider = zipformer
                DebugLogger.shared.info("Live meeting: using streaming-zipformer for live utterances", source: "LiveMeetingTranscriptionService")
            } catch {
                self.stopMicrophone()
                await self.systemCapture.stop()
                self.status = ""
                self.errorMessage = "实时转写模型加载失败：\(error.localizedDescription)"
                return
            }
        case .highQuality:
            let fireRed = FireRedAsrProvider()
            do {
                try await fireRed.prepare(progressHandler: nil)
                self.liveUtteranceProvider = fireRed
                DebugLogger.shared.info("Live meeting: using FireRedASR for quasi-realtime live utterances", source: "LiveMeetingTranscriptionService")
            } catch {
                self.stopMicrophone()
                await self.systemCapture.stop()
                self.status = ""
                self.errorMessage = "实时转写模型加载失败：\(error.localizedDescription)"
                return
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
            for segment in segmenter.flush()
                where Double(segment.samples.count) / self.sampleRate >= self.minUtteranceSeconds
            {
                let startTime = Double(segment.startSample) / self.sampleRate
                self.pendingUtterances.append(PendingUtterance(startTime: startTime, samples: segment.samples))
            }
        } else {
            self.flushCurrentUtterance()
        }

        // Let the transcription worker drain the queue, then stop it.
        await self.drainPendingUtterances()
        self.transcribeLoopTask?.cancel()
        self.transcribeLoopTask = nil
        self.partialText = ""

        // Release the preview stream after any in-flight preview decode has drained (serialized so
        // the stream is never freed mid-decode).
        if let previewStreamProvider = self.previewStreamProvider {
            _ = try? await self.asrService.runSerializedTranscription {
                previewStreamProvider.releasePreviewStream()
                return true
            }
            self.previewStreamProvider = nil
        }

        let duration = self.startDate.map { Date().timeIntervalSince($0) } ?? self.elapsedSeconds
        self.startDate = nil
        self.mixer.reset()
        self.audioLevel = 0
        self.status = ""

        let text = self.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
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
            self.persistRefinementAudio(entryID: result.id)
        }
        self.refineItems = []
        DebugLogger.shared.info("Live meeting transcription stopped", source: "LiveMeetingTranscriptionService")
    }

    /// Persists each retained utterance's audio to disk keyed by the saved history entry so refinement
    /// can be triggered on demand later. No-op unless audio was retained (streaming sessions).
    private func persistRefinementAudio(entryID: UUID) {
        guard self.retainAudioForRefinement, !self.refineItems.isEmpty else { return }
        let samplesByLine = Dictionary(self.refineItems.map { ($0.id, $0.samples) }, uniquingKeysWith: { first, _ in first })
        let segments: [(lineID: UUID, startTime: TimeInterval, text: String, samples: [Float])] = self.lines.compactMap { line in
            guard let samples = samplesByLine[line.id] else { return nil }
            return (lineID: line.id, startTime: line.startTime, text: line.text, samples: samples)
        }
        MeetingRefinementStore.shared.save(entryID: entryID, endDate: Date(), segments: segments)
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
        self.processVAD(block: block)
    }

    /// Voice-activity segmentation: accumulate speech into an utterance, drop inter-utterance
    /// silence, and enqueue a completed utterance when a pause is detected or the cap is reached.
    private func processVAD(block: [Float]) {
        guard !block.isEmpty else { return }
        let blockStartSample = self.totalSamplesProcessed
        self.totalSamplesProcessed += block.count

        if let segmenter = self.vadSegmenter {
            let completed = segmenter.acceptWaveform(block)
            for segment in completed
                where Double(segment.samples.count) / self.sampleRate >= self.minUtteranceSeconds
            {
                let startTime = Double(segment.startSample) / self.sampleRate
                self.pendingUtterances.append(PendingUtterance(startTime: startTime, samples: segment.samples))
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
            if !self.inSpeech {
                self.currentSegmentStartSample = blockStartSample
            }
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
        let startTime = Double(self.currentSegmentStartSample) / self.sampleRate
        self.pendingUtterances.append(PendingUtterance(startTime: startTime, samples: utterance))
    }

    // MARK: - Live partial preview

    /// Queues newly captured speech and throttles an incremental decode so the user sees tentative
    /// text before the utterance closes. No-op unless a streaming-capable preview provider is active.
    private func accumulatePreview(_ block: [Float]) {
        guard self.previewStreamProvider != nil else { return }
        self.previewDelta.append(contentsOf: block)
        self.schedulePreviewIfNeeded()
    }

    /// Ends the current preview: bumps the token so late decodes are dropped, drops any unfed audio,
    /// clears the tentative text, and marks the preview stream to be reset before the next utterance.
    /// Called whenever an utterance finalizes or the session stops.
    private func resetPreview() {
        self.previewToken &+= 1
        self.previewDelta.removeAll(keepingCapacity: true)
        self.previewNeedsReset = true
        if !self.partialText.isEmpty {
            self.partialText = ""
        }
    }

    private func schedulePreviewIfNeeded() {
        guard let provider = self.previewStreamProvider, !self.isPreviewing else { return }
        guard !self.previewDelta.isEmpty else { return }
        guard Date().timeIntervalSince(self.lastPreviewAt) >= self.previewThrottleSeconds else { return }

        self.lastPreviewAt = Date()
        self.isPreviewing = true
        let delta = self.previewDelta
        self.previewDelta = []
        let needsReset = self.previewNeedsReset
        self.previewNeedsReset = false
        let token = self.previewToken
        Task { [weak self, provider] in
            await self?.runPreview(delta, provider: provider, needsReset: needsReset, token: token)
        }
    }

    private func runPreview(_ samples: [Float], provider: IncrementalStreamingPreview, needsReset: Bool, token: Int) async {
        defer { self.isPreviewing = false }
        guard self.isRunning else { return }
        do {
            // Reset + feed run inside the serialized queue so preview decodes never overlap the
            // per-utterance final decode on the same model, and the stream is never freed mid-decode.
            let text = try await self.asrService.runSerializedTranscription { [provider] in
                if needsReset { provider.resetPreviewStream() }
                return provider.feedPreviewStream(samples)
            }
            // Drop stale results: the utterance may have finalized (or session stopped) meanwhile.
            guard self.isRunning, token == self.previewToken else { return }
            self.partialText = text
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

    private func transcribeAndAppend(_ utterance: PendingUtterance) async {
        do {
            let provider = self.liveUtteranceProvider ?? self.asrService.fileTranscriptionProvider
            let result = try await self.asrService.runSerializedTranscription { [provider, samples = utterance.samples] in
                try await provider.transcribeFinal(samples)
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let line = MeetingTranscriptLine(startTime: utterance.startTime, text: text)
            self.lines.append(line)
            if self.retainAudioForRefinement {
                self.refineItems.append((id: line.id, samples: utterance.samples))
            }
        } catch {
            DebugLogger.shared.warning("Live utterance transcription failed: \(error)", source: "LiveMeetingTranscriptionService")
        }
    }

    // MARK: - Audio helpers

    /// Formats seconds from session start as `MM:SS` for line timestamps.
    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

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
