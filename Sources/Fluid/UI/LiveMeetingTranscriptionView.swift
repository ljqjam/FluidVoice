import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LiveMeetingTranscriptionView: View {
    @StateObject private var service: LiveMeetingTranscriptionService
    @Environment(\.theme) private var theme

    @State private var showingCopyConfirmation = false
    @State private var showingExportDialog = false

    init(asrService: ASRService) {
        _service = StateObject(wrappedValue: LiveMeetingTranscriptionService(asrService: asrService))
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            ScrollView {
                VStack(spacing: 24) {
                    self.controlCard
                    if let error = service.errorMessage {
                        self.errorCard(error: error)
                    }
                    self.transcriptCard
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.windowBackground)
        .overlay(alignment: .topTrailing) {
            if self.showingCopyConfirmation {
                Text("已复制！")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.fluidGreen.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fileExporter(
            isPresented: self.$showingExportDialog,
            document: LiveMeetingTextDocument(text: self.service.liveTranscript),
            contentType: .plainText,
            defaultFilename: "实时会议转录.txt"
        ) { _ in }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.and.signal.meter.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.fluidGreen.gradient)

            Text("实时会议转录")
                .font(.title2)
                .fontWeight(.semibold)

            Text("同时转写系统声音与麦克风，实时生成会议记录")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
        .padding(.bottom, 30)
    }

    // MARK: - Control Card

    private var controlCard: some View {
        VStack(spacing: 16) {
            HStack {
                Button(action: {
                    Task {
                        if self.service.isRunning {
                            await self.service.stop()
                        } else {
                            await self.service.start()
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: self.service.isRunning ? "stop.fill" : "record.circle")
                        Text(self.service.isRunning ? "停止" : "开始")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(self.service.isRunning ? .red : Color.fluidGreen)
            }

            if self.service.isRunning || !self.service.status.isEmpty {
                HStack(spacing: 12) {
                    if self.service.isRunning {
                        Image(systemName: "waveform")
                            .foregroundColor(Color.fluidGreen)
                        AudioLevelBar(level: self.service.audioLevel)
                            .frame(height: 10)
                        Text(self.formatDuration(self.service.elapsedSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    if !self.service.status.isEmpty {
                        Text(self.service.status)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .background(self.cardBackground(cornerRadius: 12))
    }

    // MARK: - Transcript Card

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("转录内容")
                    .font(.headline)
                Spacer()
                if !self.service.lines.isEmpty {
                    Button(action: { self.copyToClipboard(self.service.liveTranscript) }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("复制到剪贴板")
                    Button(action: { self.showingExportDialog = true }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("导出为文本")
                }
            }
            .buttonStyle(.borderless)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if self.service.lines.isEmpty, self.service.partialText.isEmpty {
                            Text(self.service.isRunning ? "正在聆听…" : "点击「开始」采集系统声音与麦克风，实时转写会议内容。")
                                .font(.body)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(self.service.lines) { line in
                                self.transcriptLine(
                                    timestamp: self.formatDuration(line.startTime),
                                    text: line.text,
                                    isPartial: false
                                )
                            }
                            if !self.service.partialText.isEmpty {
                                self.transcriptLine(
                                    timestamp: self.formatDuration(self.service.elapsedSeconds),
                                    text: self.service.partialText,
                                    isPartial: true
                                )
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .frame(minHeight: 260, maxHeight: 420)
                .background(self.cardBackground(cornerRadius: 8, fill: self.theme.palette.contentBackground))
                .onChange(of: self.service.lines) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: self.service.partialText) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .padding()
        .background(self.cardBackground(cornerRadius: 12))
    }

    /// One meeting transcript block: a `[MM:SS]` timestamp label above the utterance text.
    /// Partial (not-yet-finalized) lines are dimmed.
    private func transcriptLine(timestamp: String, text: String, isPartial: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            Text(text)
                .font(.body)
                .foregroundColor(isPartial ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Error Card

    private func errorCard(error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.subheadline)
                Spacer()
            }
            if error.contains("屏幕录制") {
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private func cardBackground(cornerRadius: CGFloat, fill: Color? = nil) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill ?? self.theme.palette.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
            )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { self.showingCopyConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { self.showingCopyConfirmation = false }
        }
    }
}

// MARK: - Audio Level Bar

private struct AudioLevelBar: View {
    let level: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.fluidGreen)
                    .frame(width: max(2, geo.size.width * min(1, max(0, self.level))))
            }
        }
        .frame(width: 80)
    }
}

// MARK: - Export Document

private struct LiveMeetingTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(self.text.utf8))
    }
}
