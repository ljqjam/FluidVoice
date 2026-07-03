import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionHistoryView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @Environment(\.theme) private var theme

    @State private var searchQuery: String = ""
    @State private var showClearConfirmation: Bool = false
    @State private var showReportConfirmation: Bool = false
    @State private var selectedReportEntry: TranscriptionHistoryEntry?
    @State private var selectedEntryID: UUID?

    private var filteredEntries: [TranscriptionHistoryEntry] {
        self.historyStore.search(query: self.searchQuery)
    }

    private var selectedEntry: TranscriptionHistoryEntry? {
        guard let id = selectedEntryID else { return self.filteredEntries.first }
        return self.filteredEntries.first(where: { $0.id == id })
    }

    var body: some View {
        HSplitView {
            // MARK: - Left Panel: Entry List

            VStack(spacing: 0) {
                // Search Bar
                self.searchBar
                    .padding(12)

                Divider()
                    .opacity(0.3)

                // Entry List
                if self.filteredEntries.isEmpty {
                    self.emptyStateView
                } else {
                    self.entryListView
                }

                // Footer with stats and clear button
                self.footerView
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            .background(self.theme.palette.contentBackground)

            // MARK: - Right Panel: Entry Detail

            if let entry = selectedEntry {
                self.entryDetailView(entry)
                    .frame(minWidth: 400)
            } else {
                self.noSelectionView
                    .frame(minWidth: 400)
            }
        }
        .onAppear {
            if self.selectedEntryID == nil {
                self.selectedEntryID = self.filteredEntries.first?.id
            }
        }
        .alert("清空历史记录", isPresented: self.$showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("全部清除", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.historyStore.clearAllHistory()
                    self.selectedEntryID = nil
                }
            }
        } message: {
            Text("此操作将永久删除全部 \(self.historyStore.entries.count) 条转录记录，且无法撤销。")
        }
        .alert("反馈已发送", isPresented: self.$showReportConfirmation) {
            Button("好", role: .cancel) {}
        } message: {
            Text("感谢您帮助改善 FluidVoice 的听写功能。")
        }
        .sheet(item: self.$selectedReportEntry) { entry in
            TranscriptionFeedbackReportSheet(entry: entry) {
                self.selectedReportEntry = nil
                self.showReportConfirmation = true
            }
            .environment(\.theme, self.theme)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索转录记录…", text: self.$searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !self.searchQuery.isEmpty {
                Button {
                    self.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(self.theme.palette.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)))
    }

    // MARK: - Entry List

    private var entryListView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(self.filteredEntries) { entry in
                    self.entryRow(entry)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func entryRow(_ entry: TranscriptionHistoryEntry) -> some View {
        let isSelected = self.selectedEntryID == entry.id

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                self.selectedEntryID = entry.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                // Top row: App name and time
                HStack(spacing: 6) {
                    Text(entry.appName.isEmpty ? "未知应用" : entry.appName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .lineLimit(1)

                    if entry.wasAIProcessed {
                        Text("AI")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : self.theme.palette.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isSelected ? .white.opacity(0.2) : self.theme.palette.accent.opacity(0.15))
                            )
                    }

                    if self.hasAudio(entry) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : self.theme.palette.accent)
                            .help("已保存本地听写音频")
                    }

                    if entry.aiProcessingError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isSelected ? .white : Color.orange)
                            .help(entry.aiProcessingError ?? "")
                    }

                    Spacer()

                    Text(entry.relativeTimeString)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : Color.secondary.opacity(0.6))
                }

                // Preview text
                Text(entry.previewText)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? self.theme.palette.accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                self.copyToClipboard(entry.processedText)
            } label: {
                Label(entry.wasAIProcessed ? "复制 AI 文本" : "复制文本", systemImage: "doc.on.doc")
            }

            if entry.wasAIProcessed {
                Button {
                    self.copyToClipboard(entry.rawText)
                } label: {
                    Label("复制原始文本", systemImage: "doc.on.doc.fill")
                }

                Button {
                    self.copyToClipboard(self.combinedText(for: entry))
                } label: {
                    Label("全部复制", systemImage: "doc.on.doc")
                }
            }

            if self.hasAudio(entry) {
                Divider()

                Button {
                    self.exportPair(entry)
                } label: {
                    Label("导出配对…", systemImage: "square.and.arrow.up")
                }

                Button {
                    self.revealAudio(entry)
                } label: {
                    Label("显示音频文件", systemImage: "waveform")
                }
            }

            Divider()

            Button {
                self.openFeedbackReport(for: entry)
            } label: {
                Label("报告错误结果…", systemImage: "hand.thumbsup.slash")
            }

            Divider()

            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.historyStore.deleteEntry(id: entry.id)
                    if self.selectedEntryID == entry.id {
                        self.selectedEntryID = self.filteredEntries.first(where: { $0.id != entry.id })?.id
                    }
                }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: self.searchQuery.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text(self.searchQuery.isEmpty ? "暂无历史记录" : "无结果")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(self.searchQuery.isEmpty
                    ? "您的转录记录将显示在这里"
                    : "请尝试其他搜索词")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.3)

            HStack {
                // Stats
                Text("\(self.historyStore.entries.count) 条记录")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                Spacer()

                // Clear All Button
                if !self.historyStore.entries.isEmpty {
                    Button {
                        self.showClearConfirmation = true
                    } label: {
                        Text("全部清除")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Entry Detail View

    private func entryDetailView(_ entry: TranscriptionHistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("转录详情")
                            .font(.system(size: 18, weight: .semibold))

                        Spacer()

                        Button {
                            self.copyToClipboard(entry.processedText)
                        } label: {
                            Label(entry.wasAIProcessed ? "复制 AI" : "复制", systemImage: "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if self.hasAudio(entry) {
                            Button {
                                self.exportPair(entry)
                            } label: {
                                Label("导出配对", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                self.revealAudio(entry)
                            } label: {
                                Label("音频", systemImage: "waveform")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button {
                            self.openFeedbackReport(for: entry)
                        } label: {
                            Label("报告", systemImage: "hand.thumbsup.slash")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("查看并将此示例发送给 FluidVoice")

                        if entry.wasAIProcessed {
                            Button {
                                self.copyToClipboard(entry.rawText)
                            } label: {
                                Label("原始", systemImage: "doc.on.doc.fill")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                self.copyToClipboard(self.combinedText(for: entry))
                            } label: {
                                Label("全部", systemImage: "doc.on.doc")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    Text(entry.fullDateString)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .opacity(0.3)

                if let aiError = entry.aiProcessingError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI 增强失败 — 已直接输入原始转录内容")
                                .font(.system(size: 12, weight: .semibold))
                            Text(aiError)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.orange.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                    )
                }

                // Final Text Section
                self.detailSection(
                    title: "最终文本",
                    content: entry.processedText,
                    badge: entry.wasAIProcessed ? "AI 增强" : nil
                )

                // Raw Text Section (only if different)
                if entry.wasAIProcessed {
                    self.detailSection(
                        title: "原始转录",
                        content: entry.rawText,
                        badge: nil,
                        isSecondary: true
                    )
                }

                Divider()
                    .opacity(0.3)

                // Metadata Grid
                self.metadataGrid(entry)

                Spacer(minLength: 20)

                // Delete Button
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let nextEntry = self.filteredEntries.first(where: { $0.id != entry.id })
                            self.historyStore.deleteEntry(id: entry.id)
                            self.selectedEntryID = nextEntry?.id
                        }
                    } label: {
                        Label("删除记录", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
            .padding(24)
        }
        .background(self.theme.palette.contentBackground)
    }

    private func detailSection(
        title: String,
        content: String,
        badge: String?,
        isSecondary: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(self.theme.palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(self.theme.palette.accent.opacity(0.15))
                        )
                }
            }

            Text(content)
                .font(.system(size: 14, design: .default))
                .foregroundStyle(isSecondary ? .secondary : .primary)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(self.theme.palette.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(self.theme.palette.cardBorder.opacity(isSecondary ? 0.35 : 0.5), lineWidth: 1)))
        }
    }

    private func metadataGrid(_ entry: TranscriptionHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("详细信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ], spacing: 12) {
                self.metadataItem(icon: "app.fill", label: "应用程序", value: entry.appName.isEmpty ? "未知" : entry.appName)
                self.metadataItem(icon: "macwindow", label: "窗口", value: entry.windowTitle.isEmpty ? "未知" : entry.windowTitle)
                self.metadataItem(icon: "character.cursor.ibeam", label: "字符数", value: "\(entry.characterCount)")
                self.metadataItem(icon: "sparkles", label: "AI 处理", value: entry.wasAIProcessed ? "是" : "否")
                self.metadataItem(icon: "waveform", label: "音频", value: self.audioMetadataText(for: entry))
            }
        }
    }

    private func metadataItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(self.theme.palette.cardBackground.opacity(0.9)))
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openFeedbackReport(for entry: TranscriptionHistoryEntry) {
        self.selectedReportEntry = entry
    }

    private func combinedText(for entry: TranscriptionHistoryEntry) -> String {
        "\(entry.rawText)\n\n\(entry.processedText)"
    }

    private func hasAudio(_ entry: TranscriptionHistoryEntry) -> Bool {
        DictationAudioHistoryStore.shared.audioFileExists(for: entry)
    }

    private func audioMetadataText(for entry: TranscriptionHistoryEntry) -> String {
        guard let audio = entry.audio, self.hasAudio(entry) else { return "无" }
        let seconds = Double(audio.durationMilliseconds) / 1000.0
        let size = ByteCountFormatter.string(fromByteCount: Int64(audio.byteCount), countStyle: .file)
        return "\(String(format: "%.1f", seconds))s, \(size)"
    }

    private func revealAudio(_ entry: TranscriptionHistoryEntry) {
        guard let url = DictationAudioHistoryStore.shared.audioFileURL(for: entry),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportPair(_ entry: TranscriptionHistoryEntry) {
        do {
            guard self.hasAudio(entry) else { throw DictationAudioHistoryError.audioMissing }
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = DictationAudioHistoryStore.shared.suggestedPairExportFilename(for: entry)

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try DictationAudioHistoryStore.shared.exportPair(entry: entry, to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "配对导出失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    // MARK: - No Selection View

    private var noSelectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)

            Text("请选择一条转录记录")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.contentBackground)
    }
}

private struct TranscriptionFeedbackReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var inputText: String
    @State private var outputText: String
    @State private var processingModel: String
    @State private var comment: String
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    let onSent: () -> Void

    init(entry: TranscriptionHistoryEntry, onSent: @escaping () -> Void) {
        _inputText = State(initialValue: entry.rawText)
        _outputText = State(initialValue: entry.processedText)
        _processingModel = State(initialValue: Self.reportModel(for: entry))
        _comment = State(initialValue: "")
        self.onSent = onSent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("分享匿名数据")
                    .font(.system(size: 18, weight: .semibold))
                Text("帮助改善我们的模型，仅发送以下示例内容。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            self.feedbackField(title: "原始文本", text: self.$inputText, height: 88)
            self.feedbackField(title: "处理后文本", text: self.$outputText, height: 88)
            self.feedbackField(title: "处理模型", text: self.$processingModel, height: 40)
            self.feedbackField(title: "备注（可选）", text: self.$comment, height: 72)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") {
                    self.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(self.isSending)

                Button {
                    Task {
                        await self.sendReport()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if self.isSending {
                            ProgressView()
                                .controlSize(.small)
                                .fixedSize()
                        }
                        Text(self.isSending ? "发送中…" : "发送示例")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(self.isSendDisabled)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(self.theme.palette.contentBackground)
    }

    private var isSendDisabled: Bool {
        self.isSending ||
            (self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                self.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
            self.processingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendReport() async {
        let payload = TranscriptionFeedbackReporter.Payload(
            rawText: self.inputText.trimmingCharacters(in: .whitespacesAndNewlines),
            processedText: self.outputText.trimmingCharacters(in: .whitespacesAndNewlines),
            processingModel: self.processingModel.trimmingCharacters(in: .whitespacesAndNewlines),
            comments: self.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        self.isSending = true
        self.errorMessage = nil
        do {
            try await TranscriptionFeedbackReporter.submit(payload)
            self.isSending = false
            self.onSent()
        } catch {
            self.errorMessage = error.localizedDescription
            self.isSending = false
        }
    }

    private func feedbackField(title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(self.theme.palette.cardBorder.opacity(0.55), lineWidth: 1)
                        )
                )
        }
    }

    private static func reportModel(for entry: TranscriptionHistoryEntry) -> String {
        let model = entry.processingModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? "unknown" : model
    }
}

#Preview {
    TranscriptionHistoryView()
        .frame(width: 800, height: 600)
        .environment(\.theme, AppTheme.dark)
}
