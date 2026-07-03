//
//  CustomDictionaryView.swift
//  fluid
//
//  Custom dictionary for correcting commonly misheard words.
//  Created: 2025-12-21
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CustomDictionaryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appServices: AppServices

    private var asr: ASRService { self.appServices.asr }

    @State private var entries: [SettingsStore.CustomDictionaryEntry] = SettingsStore.shared.customDictionaryEntries
    @State private var boostTerms: [ParakeetVocabularyStore.VocabularyConfig.Term] = []
    @State private var editingEntry: SettingsStore.CustomDictionaryEntry?
    @State private var showAddBoostSheet = false
    @State private var editingBoostTerm: EditableBoostTerm?

    @State private var boostStatusMessage = "添加自定义词汇以提升 Parakeet 识别效果。"
    @State private var boostHasError = false
    @State private var vocabBoostingEnabled: Bool = SettingsStore.shared.vocabularyBoostingEnabled
    @State private var isBoostingInfoPresented = false

    @State private var trainingReplacement = ""
    @State private var trainingVariants: [String] = []
    @State private var trainingSampleCount = 0
    @State private var lastTrainingOutput = ""
    @State private var lastTrainingOutputIsCovered = false
    @State private var consecutiveCoveredCaptures = 0
    @State private var trainingStatusMessage = "请输入正确文本。"
    @State private var trainingHasError = false
    @State private var isTrainingActive = false
    @State private var isTrainingStarting = false
    @State private var isTrainingRecording = false
    @State private var trainingStopRequestedDuringStart = false
    @State private var isTrainingProcessing = false
    @State private var replacementConfirmation: ReplacementConfirmation?
    @State private var composerMode: DictionaryComposerMode = .train
    @State private var manualTriggersText = ""
    @State private var manualReplacement = ""
    @State private var isDictionaryExpanded = false

    private var normalizedTrainingReplacement: String {
        self.trainingReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trainingProgressText: String {
        let count = self.trainingSampleCount
        return "\(count) 个样本 · 最多 \(CustomDictionaryTrainingMerge.maxSamples) 个"
    }

    private var shouldShowTrainingStatus: Bool {
        self.trainingHasError || (
            !self.trainingStatusMessage.isEmpty &&
                self.trainingStatusMessage != "请输入正确文本。"
        )
    }

    private var canUseTrainingRecorderButton: Bool {
        guard !self.trainingStopRequestedDuringStart, !self.isTrainingProcessing else { return false }
        return self.isTrainingRecording || self.canRecordTrainingSample
    }

    private var trainingRecorderTitle: String {
        if self.trainingStopRequestedDuringStart {
            return "正在停止…"
        }
        if self.isTrainingProcessing {
            return "正在处理…"
        }
        if self.isTrainingStarting {
            return "正在启动…"
        }
        if self.isTrainingRecording {
            return "正在聆听…"
        }
        if self.normalizedTrainingReplacement.isEmpty {
            return "录制示例"
        }
        return self.trainingVariants.isEmpty ? "说一遍" : "再说一遍"
    }

    private var trainingRecorderDetail: String {
        self.normalizedTrainingReplacement.isEmpty
            ? "请先输入正确文本。"
            : "请持续尝试，直到 FluidVoice 连续 3 次正确识别。"
    }

    private var trainingRecorderStatusText: String {
        guard !self.lastTrainingOutput.isEmpty else { return "录音以检测" }
        if self.trainingAlreadyCorrectWithoutReplacement {
            return "已正确识别"
        }
        if self.trainingFinalOutputIsReady {
            return "已准备就绪"
        }
        return "\(self.trainingReadinessProgress)/\(CustomDictionaryTrainingMerge.readyCoveredCount) 已识别"
    }

    private var trainingRecorderStatusColor: Color {
        self.trainingFinalOutputIsReady || self.trainingAlreadyCorrectWithoutReplacement
            ? self.theme.palette.success
            : self.theme.palette.secondaryText
    }

    private var trainingRecorderFillColor: Color {
        self.trainingFinalOutputIsReady || self.trainingAlreadyCorrectWithoutReplacement
            ? self.theme.palette.success
            : self.theme.palette.accent
    }

    private var trainingRecorderFillFraction: Double {
        guard !self.lastTrainingOutput.isEmpty else { return 0 }
        if self.trainingAlreadyCorrectWithoutReplacement {
            return 1
        }
        return Double(self.trainingReadinessProgress) / Double(CustomDictionaryTrainingMerge.readyCoveredCount)
    }

    private var trainingFinalOutputIsReady: Bool {
        !self.trainingAlreadyCorrectWithoutReplacement &&
            self.trainingOutputIsCovered &&
            self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount
    }

    private var trainingAlreadyCorrectWithoutReplacement: Bool {
        self.trainingVariants.isEmpty &&
            self.trainingOutputIsCovered &&
            !self.lastTrainingOutput.isEmpty &&
            self.lastTrainingOutput.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame &&
            self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount
    }

    private var trainingReadinessProgress: Int {
        guard !self.trainingAlreadyCorrectWithoutReplacement else {
            return CustomDictionaryTrainingMerge.readyCoveredCount
        }
        guard self.trainingOutputIsCovered else { return 0 }
        return min(self.consecutiveCoveredCaptures, CustomDictionaryTrainingMerge.readyCoveredCount)
    }

    private var trainingOutputIsCovered: Bool {
        self.lastTrainingOutputIsCovered
    }

    private var trainingFinalOutputText: String {
        guard !self.lastTrainingOutput.isEmpty else { return "Record to check" }
        return self.trainingOutputIsCovered ? self.normalizedTrainingReplacement : self.lastTrainingOutput
    }

    private var canStartTraining: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.isTrainingRecording &&
            !self.isTrainingProcessing
    }

    private var canRecordTrainingSample: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.isTrainingProcessing &&
            !self.asr.isRunning &&
            self.trainingSampleCount < CustomDictionaryTrainingMerge.maxSamples
    }

    private var canAddTrainedReplacement: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.trainingVariants.isEmpty &&
            !self.isTrainingRecording &&
            !self.isTrainingProcessing
    }

    private var trainedReplacementButtonTitle: String {
        self.trainingAlreadyCorrectWithoutReplacement ? "无需替换" : "添加替换"
    }

    private var shouldEmphasizeTrainedReplacementButton: Bool {
        self.trainingFinalOutputIsReady && self.canAddTrainedReplacement
    }

    private var manualTriggers: [String] {
        CustomDictionaryManualEntry.parseTriggers(self.manualTriggersText)
    }

    private var manualDuplicateTriggers: [String] {
        self.manualTriggers.filter { self.allExistingTriggers().contains($0) }
    }

    private var canAddManualReplacement: Bool {
        !self.manualTriggers.isEmpty &&
            !self.manualReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            self.manualDuplicateTriggers.isEmpty
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                self.pageHeader

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
                    self.trainReplacementSection
                    self.yourDictionarySection
                    self.aiPostProcessingSection
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(self.theme.metrics.spacing.xl)
        }
        .overlay {
            if let confirmation = self.replacementConfirmation {
                ReplacementConfirmationToast(confirmation: confirmation)
                    .padding(self.theme.metrics.spacing.xl)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: self.$editingEntry) { entry in
            EditDictionaryEntrySheet(
                entry: entry,
                existingTriggers: self.allExistingTriggers(excluding: entry.id)
            ) { updatedEntry in
                if let index = self.entries.firstIndex(where: { $0.id == updatedEntry.id }) {
                    self.entries[index] = updatedEntry
                    self.saveEntries()
                }
            }
        }
        .sheet(isPresented: self.$showAddBoostSheet) {
            AddBoostTermSheet(existingTerms: self.existingBoostTerms()) { newTerm in
                self.boostTerms.append(newTerm)
                self.saveBoostTerms()
            }
        }
        .sheet(item: self.$editingBoostTerm) { editable in
            EditBoostTermSheet(
                term: editable.term,
                existingTerms: self.existingBoostTerms(excludingIndex: editable.index)
            ) { updatedTerm in
                guard self.boostTerms.indices.contains(editable.index) else { return }
                self.boostTerms[editable.index] = updatedTerm
                self.saveBoostTerms()
            }
        }
        .onAppear {
            self.loadBoostTerms()
        }
        .onDisappear {
            guard self.isTrainingRecording else { return }
            Task { @MainActor in
                await self.stopTrainingSample()
            }
        }
    }

    // MARK: - Page Header

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            self.settingsIconTile(systemName: "text.book.closed.fill")

            VStack(alignment: .leading, spacing: 2) {
                Text("自定义词典")
                    .font(self.theme.typography.title)
                Text("纠正反复出现的错误，让语音引擎学习您常用的词汇。")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            Spacer(minLength: self.theme.metrics.spacing.md)

            HStack(spacing: self.theme.metrics.spacing.sm) {
                Button(action: self.importDictionary) {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .fluidButton(.compact, size: .compact)

                Button(action: self.exportDictionary) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .fluidButton(.compact, size: .compact)
            }
        }
    }

    private func settingsIconTile(systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.82))
                .overlay(
                    LinearGradient(
                        colors: [.white.opacity(0.1), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.35), lineWidth: 1)
                )

            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(self.theme.palette.accent)
        }
        .frame(width: 34, height: 34)
    }

    // MARK: - Teach Words

    private var trainReplacementSection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                    self.settingsIconTile(systemName: "mic.fill")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("教学单词")
                            .font(self.theme.typography.sectionTitle)
                        Text("通过语音或手动输入，向 FluidVoice 展示正确的拼写。")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                }

                self.dictionaryComposerModePicker

                Group {
                    switch self.composerMode {
                    case .train:
                        self.trainReplacementComposer
                    case .manual:
                        self.manualReplacementComposer
                    }
                }
                .frame(minHeight: 315, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dictionaryComposerModePicker: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            self.dictionaryComposerModeSegmented

            Text(self.composerMode.detail)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dictionaryComposerModeSegmented: some View {
        HStack(spacing: 2) {
            ForEach(DictionaryComposerMode.allCases) { mode in
                DictionaryComposerModeTab(
                    mode: mode,
                    isSelected: self.composerMode == mode,
                    isDisabled: self.isTrainingRecording || self.isTrainingProcessing
                ) {
                    self.selectComposerMode(mode)
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var trainReplacementComposer: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            TextField("输入正确文本，例如 FluidVoice", text: self.$trainingReplacement)
                .textFieldStyle(.roundedBorder)
                .disabled(self.isTrainingRecording || self.isTrainingProcessing)
                .onChange(of: self.trainingReplacement) { oldValue, newValue in
                    self.handleTrainingReplacementChange(oldValue: oldValue, newValue: newValue)
                }

            self.trainingRecorderPanel

            self.trainingFinalOutputPanel

            if !self.trainingVariants.isEmpty {
                self.trainingHeardSection
            }

            self.trainingFooter

            Spacer(minLength: 0)

            Button {
                self.addTrainedReplacement()
            } label: {
                Label(self.trainedReplacementButtonTitle, systemImage: self.trainingAlreadyCorrectWithoutReplacement ? "checkmark" : "plus")
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
            }
            .fluidButton(.accent, size: .small)
            .disabled(!self.canAddTrainedReplacement)
            .opacity(self.canAddTrainedReplacement ? 1 : 0.45)
            .overlay(self.trainedReplacementButtonReadyOutline)
            .shadow(
                color: self.shouldEmphasizeTrainedReplacementButton ? self.theme.palette.success.opacity(0.18) : .clear,
                radius: self.shouldEmphasizeTrainedReplacementButton ? 14 : 0,
                x: 0,
                y: 5
            )
            .scaleEffect(self.shouldEmphasizeTrainedReplacementButton ? 1.006 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: self.shouldEmphasizeTrainedReplacementButton)
        }
    }

    private var trainedReplacementButtonReadyOutline: some View {
        RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
            .stroke(
                self.shouldEmphasizeTrainedReplacementButton ? self.theme.palette.success.opacity(0.72) : .clear,
                lineWidth: 1.5
            )
            .padding(-3)
            .allowsHitTesting(false)
    }

    private var manualReplacementComposer: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    self.manualTriggerField
                    self.manualReplacementField
                }

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    self.manualTriggerField
                    self.manualReplacementField
                }
            }

            if !self.manualDuplicateTriggers.isEmpty {
                Label("已被使用：\(self.manualDuplicateTriggers.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }

            if !self.manualTriggers.isEmpty || !self.manualReplacement.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(self.manualTriggers, id: \.self) { trigger in
                        DictionaryPreviewChip(text: trigger)
                    }

                    Image(systemName: "arrow.right")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)

                    Text(self.manualReplacement.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.accent)
                }
            }

            Spacer(minLength: 0)

            Button {
                self.addManualReplacementIfValid()
            } label: {
                Label("添加替换", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
            }
            .fluidButton(.accent, size: .small)
            .disabled(!self.canAddManualReplacement)
            .opacity(self.canAddManualReplacement ? 1 : 0.45)
        }
    }

    private var manualTriggerField: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text("当 FluidVoice 听到")
                .font(self.theme.typography.captionStrong)
            TextField("fluid voice, fluid boys", text: self.$manualTriggersText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { self.addManualReplacementIfValid() }
            Text("多个版本请用逗号分隔。")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var manualReplacementField: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text("替换为")
                .font(self.theme.typography.captionStrong)
            TextField("FluidVoice", text: self.$manualReplacement)
                .textFieldStyle(.roundedBorder)
                .onSubmit { self.addManualReplacementIfValid() }
            Text("这是最终出现在转录结果中的内容。")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var trainingRecorderPanel: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text(self.trainingRecorderTitle)
                    .font(self.theme.typography.bodySmallStrong)

                Text(self.trainingRecorderDetail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(2)

                self.trainingRecorderProgressRow

                HStack(spacing: 7) {
                    Text(self.trainingRecorderStatusText)
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.trainingRecorderStatusColor)
                        .lineLimit(1)

                    Text("· 已录制 \(self.trainingProgressText)")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task {
                    if self.isTrainingRecording {
                        await self.stopTrainingSample()
                    } else {
                        await self.startTrainingSample()
                    }
                }
            } label: {
                Label(self.isTrainingRecording ? "停止" : "录音", systemImage: self.isTrainingRecording ? "stop.fill" : "mic.fill")
            }
            .fluidButton(self.isTrainingRecording ? .destructive : .accent, size: .small)
            .disabled(!self.canUseTrainingRecorderButton)
            .opacity(self.canUseTrainingRecorderButton ? 1 : 0.45)
        }
        .padding(self.theme.metrics.spacing.md)
        .background(self.trainingRecorderBackground)
    }

    private var trainingRecorderBackground: some View {
        GeometryReader { proxy in
            let fillWidth = proxy.size.width * min(max(self.trainingRecorderFillFraction, 0), 1)

            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .fill(self.trainingRecorderFillColor.opacity(0.16))
                        .frame(width: fillWidth)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.trainingRecorderBorderColor, lineWidth: 1)
                )
                .animation(.easeOut(duration: 0.18), value: self.trainingRecorderFillFraction)
        }
        .allowsHitTesting(false)
    }

    private var trainingRecorderBorderColor: Color {
        self.trainingFinalOutputIsReady || self.trainingAlreadyCorrectWithoutReplacement
            ? self.theme.palette.success.opacity(0.28)
            : self.theme.palette.cardBorder.opacity(0.25)
    }

    private var trainingRecorderProgressBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * min(max(self.trainingRecorderFillFraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(self.theme.palette.cardBorder.opacity(0.35))

                Capsule(style: .continuous)
                    .fill(self.trainingRecorderFillColor)
                    .frame(width: width)
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.18), value: self.trainingRecorderFillFraction)
        .accessibilityHidden(true)
    }

    private var trainingRecorderProgressRow: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            self.trainingRecorderProgressBar

            Text("\(self.trainingReadinessProgress)/\(CustomDictionaryTrainingMerge.readyCoveredCount)")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.trainingRecorderStatusColor)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var trainingHeardSection: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Text("已捕获")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.secondaryText)

            HStack(spacing: 6) {
                ForEach(Array(self.trainingVariants.prefix(5).enumerated()), id: \.element) { index, variant in
                    TrainingVariantChip(number: index + 1, variant: variant) {
                        self.removeTrainingVariant(variant)
                    }
                }

                if self.trainingVariants.count > 5 {
                    Text("+\(self.trainingVariants.count - 5)")
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(self.theme.palette.cardBackground.opacity(0.65))
                        )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var trainingFinalOutputPanel: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            VStack(alignment: .leading, spacing: 5) {
                Text("最终输出")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)

                Text(self.trainingFinalOutputText)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.lastTrainingOutput.isEmpty ? self.theme.palette.tertiaryText : self.theme.palette.primaryText)
                    .lineLimit(1)

                if !self.lastTrainingOutput.isEmpty, self.lastTrainingOutput.caseInsensitiveCompare(self.trainingFinalOutputText) != .orderedSame {
                    Text("识别为：\(self.lastTrainingOutput)")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(
                            self.trainingFinalOutputIsReady ? self.theme.palette.success.opacity(0.28) : self.theme.palette.cardBorder.opacity(0.22),
                            lineWidth: 1
                        )
                )
        )
    }

    @ViewBuilder
    private var trainingFooter: some View {
        if self.shouldShowTrainingStatus || self.isTrainingActive || !self.trainingVariants.isEmpty {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.trainingHasError {
                    Label(self.trainingStatusMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                } else if self.shouldShowTrainingStatus {
                    Text(self.trainingStatusMessage)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                if self.isTrainingActive || !self.trainingVariants.isEmpty || !self.normalizedTrainingReplacement.isEmpty {
                    Spacer()

                    Button("清除") {
                        self.resetTraining()
                    }
                    .fluidButton(.compact, size: .compact)
                    .disabled(self.isTrainingRecording || self.isTrainingProcessing)
                    .opacity(self.isTrainingRecording || self.isTrainingProcessing ? 0.45 : 1)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Your Dictionary

    private var yourDictionarySection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                    self.settingsIconTile(systemName: "book.closed.fill")

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("我的词典")
                                .font(self.theme.typography.sectionTitle)
                            if !self.entries.isEmpty {
                                Text("(\(self.entries.count))")
                                    .font(self.theme.typography.captionSmall)
                                    .foregroundStyle(self.theme.palette.tertiaryText)
                            }
                        }
                        Text("FluidVoice 会自动纠正的词汇和短语。")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }

                    Spacer()

                    Button {
                        withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            self.isDictionaryExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: self.isDictionaryExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                                    .fill(self.theme.palette.contentBackground.opacity(0.45))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(self.isDictionaryExpanded ? "收起词典" : "展开词典")
                    .accessibilityLabel(self.isDictionaryExpanded ? "收起词典" : "展开词典")
                }

                if self.isDictionaryExpanded {
                    if self.entries.isEmpty {
                        self.dictionaryEmptyState(
                            title: "暂无替换规则",
                            detail: "请使用上方的“语音训练”或“手动添加”来创建第一条规则。"
                        )
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        self.entriesListView
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var entriesListView: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            ForEach(self.entries) { entry in
                DictionaryEntryRow(
                    entry: entry,
                    onEdit: { self.editingEntry = entry },
                    onDelete: { self.deleteEntry(entry) }
                )
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Custom Words

    private var aiPostProcessingSection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                    self.settingsIconTile(systemName: "character.book.closed")

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("自定义词汇")
                                .font(self.theme.typography.sectionTitle)
                            if !self.boostTerms.isEmpty {
                                Text("(\(self.boostTerms.count))")
                                    .font(self.theme.typography.captionSmall)
                                    .foregroundStyle(self.theme.palette.tertiaryText)
                            }
                        }
                        Text("帮助 Parakeet 语音引擎识别姓名、产品名称及不常见词汇。")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }

                    Spacer()

                    Toggle("词汇增强", isOn: self.$vocabBoostingEnabled)
                        .font(self.theme.typography.captionStrong)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("在使用 Parakeet 时提升自定义词汇的识别准确率。")
                        .onChange(of: self.vocabBoostingEnabled) { _, newValue in
                            SettingsStore.shared.vocabularyBoostingEnabled = newValue
                        }

                    Button {
                        self.isBoostingInfoPresented.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(SquareIconButtonStyle())
                    .help("关于词汇增强")
                    .popover(isPresented: self.$isBoostingInfoPresented, arrowEdge: .top) {
                        self.boostingInfoPopover
                    }

                    Button {
                        self.showAddBoostSheet = true
                    } label: {
                        Label("添加单词", systemImage: "plus")
                    }
                    .fluidButton(.accent, size: .small)
                }

                if self.boostTerms.isEmpty {
                    self.dictionaryEmptyState(
                        title: "暂无自定义词汇",
                        detail: "添加需要额外识别支持的名称或词汇。"
                    ) {
                        self.showAddBoostSheet = true
                    }
                } else {
                    VStack(spacing: self.theme.metrics.spacing.sm) {
                        ForEach(Array(self.boostTerms.enumerated()), id: \.offset) { index, term in
                            BoostTermRow(
                                term: term,
                                onEdit: {
                                    self.editingBoostTerm = EditableBoostTerm(index: index, term: term)
                                },
                                onDelete: {
                                    self.deleteBoostTerm(at: index)
                                }
                            )
                        }
                    }
                }

                if self.boostHasError {
                    Label(self.boostStatusMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var boostingInfoPopover: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "testtube.2")
                    .foregroundStyle(self.theme.palette.accent)
                Text("词汇增强 · 内测版")
                    .font(self.theme.typography.bodySmallStrong)
            }

            Text("词汇增强是一项实验性功能，可帮助 Parakeet 识别您的自定义词汇。")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)

            Text("启用后可能会使转录时间增加约一秒。")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)

            Text("若启用后识别效果变差、模型表现异常或出现其他问题，请关闭词汇增强。")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 310, alignment: .leading)
    }

    private func dictionaryEmptyState(
        title: String,
        detail: String,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: "plus.circle")
                .font(.title3)
                .foregroundStyle(self.theme.palette.tertiaryText)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodySmallStrong)
                Text(detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            if let action {
                Spacer()

                Button("添加", action: action)
                    .fluidButton(.compact, size: .compact)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Actions

    private func saveEntries() {
        SettingsStore.shared.customDictionaryEntries = self.entries
        // Invalidate cached regex patterns so changes take effect immediately
        ASRService.invalidateDictionaryCache()
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
    }

    private func addReplacementEntry(_ entry: SettingsStore.CustomDictionaryEntry) {
        self.entries.insert(entry, at: 0)
        self.saveEntries()
        self.showReplacementConfirmation(
            title: "已添加替换",
            detail: "已置于列表顶部。"
        )
    }

    private func selectComposerMode(_ mode: DictionaryComposerMode) {
        guard !self.isTrainingRecording, !self.isTrainingProcessing else { return }
        self.composerMode = mode
    }

    private func addManualReplacementIfValid() {
        guard self.canAddManualReplacement else { return }
        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: self.manualTriggers,
            replacement: self.manualReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        self.addReplacementEntry(entry)
        self.manualTriggersText = ""
        self.manualReplacement = ""
    }

    private func beginTrainingReplacement() {
        guard self.canStartTraining else { return }
        self.isTrainingActive = true
        self.trainingHasError = false
        self.trainingStatusMessage = ""
    }

    private func startTrainingSample() async {
        guard self.canRecordTrainingSample else { return }
        self.isTrainingActive = true
        self.trainingHasError = false
        self.trainingStatusMessage = ""
        self.trainingStopRequestedDuringStart = false
        self.isTrainingStarting = true
        self.isTrainingRecording = true

        await self.asr.start(forDictionaryTraining: true)
        self.isTrainingStarting = false
        if !self.asr.isRunning {
            self.isTrainingRecording = false
            self.trainingStopRequestedDuringStart = false
            self.trainingHasError = true
            self.trainingStatusMessage = "无法开始录音，请检查麦克风权限后重试。"
            return
        }

        if self.trainingStopRequestedDuringStart {
            await self.finishTrainingSampleStop()
        }
    }

    private func stopTrainingSample() async {
        guard self.isTrainingRecording else { return }
        guard !self.trainingStopRequestedDuringStart else { return }

        guard !self.isTrainingStarting, self.asr.isRunning else {
            self.trainingStopRequestedDuringStart = true
            self.trainingHasError = false
            self.trainingStatusMessage = "Stopping..."
            return
        }

        await self.finishTrainingSampleStop()
    }

    private func finishTrainingSampleStop() async {
        guard self.isTrainingRecording else { return }
        self.isTrainingRecording = false
        self.isTrainingStarting = false
        self.trainingStopRequestedDuringStart = false
        self.isTrainingProcessing = true
        self.trainingHasError = false
        self.trainingStatusMessage = ""

        let transcript = await self.asr.stop(forDictionaryTraining: true)
        self.isTrainingProcessing = false
        self.addTrainingVariant(from: transcript)
    }

    private func addTrainingVariant(from transcript: String) {
        guard let detected = CustomDictionaryTrainingMerge.normalizedTrigger(transcript) else {
            self.lastTrainingOutput = ""
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            self.trainingHasError = true
            self.trainingStatusMessage = "未检测到声音，请重试。"
            return
        }

        self.lastTrainingOutput = detected
        self.trainingSampleCount = min(self.trainingSampleCount + 1, CustomDictionaryTrainingMerge.maxSamples)

        if detected.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame {
            self.lastTrainingOutputIsCovered = true
            self.consecutiveCoveredCaptures += 1
            self.trainingHasError = false
            if self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount {
                self.trainingStatusMessage = self.trainingVariants.isEmpty
                    ? "识别已准确，无需替换。"
                    : "已准备就绪，可以添加此替换规则。"
            } else {
                self.trainingStatusMessage = "已覆盖，再试几次。"
            }
            return
        }

        let wasAlreadyCaptured = self.trainingVariants.contains { $0.caseInsensitiveCompare(detected) == .orderedSame }
        let wasAlreadySaved = self.savedDictionaryCovers(detected)

        if wasAlreadyCaptured || wasAlreadySaved {
            self.lastTrainingOutputIsCovered = true
            self.consecutiveCoveredCaptures += 1
            self.trainingHasError = false
            if self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount {
                self.trainingStatusMessage = "Looks ready. Add this replacement when you're ready."
            } else if wasAlreadySaved {
                self.trainingStatusMessage = "已被您的词典覆盖。"
            } else {
                self.trainingStatusMessage = "已捕获，再试几次。"
            }
            return
        }

        guard self.trainingVariants.count < CustomDictionaryTrainingMerge.maxSamples else {
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            self.trainingHasError = false
            self.trainingStatusMessage = "已达最大样本数，请添加或清除。"
            return
        }

        self.trainingVariants.append(detected)
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.trainingHasError = false
        if self.trainingSampleCount >= CustomDictionaryTrainingMerge.maxSamples || self.trainingVariants.count >= CustomDictionaryTrainingMerge.maxSamples {
            self.trainingStatusMessage = "Max samples reached. Add it or clear one."
        } else {
            self.trainingStatusMessage = "已捕获新发音，请添加替换规则。"
        }
    }

    private func addTrainedReplacement() {
        guard self.canAddTrainedReplacement else { return }
        let replacementText = self.normalizedTrainingReplacement
        let updatesExisting = self.entries.contains {
            $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame
        }
        self.entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: self.entries,
            replacement: replacementText,
            triggers: self.trainingVariants
        )
        self.saveEntries()
        self.resetTraining()
        self.showReplacementConfirmation(
            title: updatesExisting ? "替换已更新" : "已录制",
            detail: updatesExisting ? "变体已准备就绪。" : "替换规则已添加至顶部。"
        )
    }

    private func removeTrainingVariant(_ variant: String) {
        self.trainingVariants.removeAll { $0 == variant }
        self.refreshLastTrainingCoverage()
    }

    private func refreshLastTrainingCoverage() {
        guard !self.lastTrainingOutput.isEmpty else {
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            return
        }

        let matchesReplacement = self.lastTrainingOutput.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame
        let isStillCaptured = self.trainingVariants.contains {
            $0.caseInsensitiveCompare(self.lastTrainingOutput) == .orderedSame
        }

        if matchesReplacement || isStillCaptured || self.savedDictionaryCovers(self.lastTrainingOutput) {
            self.lastTrainingOutputIsCovered = true
        } else {
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
        }
    }

    private func resetTraining(statusMessage: String = "请输入正确文本。") {
        self.trainingReplacement = ""
        self.trainingVariants = []
        self.trainingSampleCount = 0
        self.lastTrainingOutput = ""
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.trainingStatusMessage = statusMessage
        self.trainingHasError = false
        self.isTrainingActive = false
        self.isTrainingStarting = false
        self.isTrainingRecording = false
        self.trainingStopRequestedDuringStart = false
        self.isTrainingProcessing = false
    }

    private func handleTrainingReplacementChange(oldValue: String, newValue: String) {
        let oldKey = CustomDictionaryTrainingMerge.normalizedReplacement(oldValue).lowercased()
        let newKey = CustomDictionaryTrainingMerge.normalizedReplacement(newValue).lowercased()
        guard oldKey != newKey else { return }

        self.trainingVariants = self.existingTrainingVariants(for: newValue)
        self.trainingSampleCount = 0
        self.lastTrainingOutput = ""
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.isTrainingActive = false
        if newKey.isEmpty {
            self.trainingStatusMessage = "请输入正确文本。"
        } else if self.trainingVariants.isEmpty {
            self.trainingStatusMessage = ""
        } else {
            self.trainingStatusMessage = "已加载 \(self.trainingVariants.count) 个已保存的发音样本。"
        }
        self.trainingHasError = false
    }

    private func existingTrainingVariants(for replacement: String) -> [String] {
        let replacementText = CustomDictionaryTrainingMerge.normalizedReplacement(replacement)
        guard !replacementText.isEmpty else { return [] }

        let triggers = self.entries
            .filter { $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame }
            .flatMap(\.triggers)

        return CustomDictionaryTrainingMerge.normalizedTriggers(
            from: triggers,
            intendedReplacement: replacementText
        )
    }

    private func savedDictionaryCovers(_ trigger: String) -> Bool {
        guard let triggerKey = CustomDictionaryTrainingMerge.normalizedTrigger(trigger),
              !self.normalizedTrainingReplacement.isEmpty
        else {
            return false
        }

        return self.entries.contains { entry in
            entry.replacement.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame &&
                entry.triggers.contains { savedTrigger in
                    guard let savedKey = CustomDictionaryTrainingMerge.normalizedTrigger(savedTrigger) else { return false }
                    return savedKey == triggerKey
                }
        }
    }

    private func showReplacementConfirmation(title: String, detail: String) {
        let confirmation = ReplacementConfirmation(title: title, detail: detail)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        withAnimation(self.reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.78)) {
            self.replacementConfirmation = confirmation
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_650_000_000)
            guard self.replacementConfirmation?.id == confirmation.id else { return }
            withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.16)) {
                self.replacementConfirmation = nil
            }
        }
    }

    private func loadBoostTerms() {
        do {
            self.boostTerms = try ParakeetVocabularyStore.shared.loadUserBoostTerms()
            self.boostStatusMessage = "已加载 \(self.boostTerms.count) 个自定义词汇。"
            self.boostHasError = false
        } catch {
            self.boostTerms = []
            self.boostStatusMessage = "无法加载自定义词汇：\(error.localizedDescription)"
            self.boostHasError = true
        }
    }

    private func saveBoostTerms() {
        do {
            try ParakeetVocabularyStore.shared.saveUserBoostTerms(self.boostTerms)
            self.boostStatusMessage = "已保存 \(self.boostTerms.count) 个自定义词汇。"
            self.boostHasError = false
        } catch {
            self.boostStatusMessage = "无法保存自定义词汇：\(error.localizedDescription)"
            self.boostHasError = true
        }
    }

    private func exportDictionary() {
        do {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = DictionaryTransferService.shared.suggestedFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let document = try DictionaryTransferService.shared.makeExportDocument()
            let data = try DictionaryTransferService.shared.encode(document)
            try data.write(to: url, options: .atomic)

            self.presentInfoAlert(
                title: "词典已导出",
                message: "已保存 \(document.replacements.count) 条替换规则和 \(document.customWords.count) 个自定义词汇。"
            )
        } catch {
            self.presentErrorAlert(title: "词典导出失败", message: error.localizedDescription)
        }
    }

    private func importDictionary() {
        do {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let data = try Data(contentsOf: url)
            let document = try DictionaryTransferService.shared.decode(data)
            guard let mode = self.confirmDictionaryImport(document) else { return }

            let summary = try DictionaryTransferService.shared.restore(document, mode: mode)
            self.entries = SettingsStore.shared.customDictionaryEntries
            self.loadBoostTerms()

            self.presentInfoAlert(
                title: "词典已导入",
                message: "现已使用 \(summary.replacementCount) 条替换规则和 \(summary.customWordCount) 个自定义词汇。"
            )
        } catch {
            self.presentErrorAlert(title: "词典导入失败", message: error.localizedDescription)
        }
    }

    private func confirmDictionaryImport(_ document: DictionaryTransferDocument) -> DictionaryTransferImportMode? {
        let confirm = NSAlert()
        confirm.messageText = "是否导入此词典？"
        confirm.informativeText = """
        发现 \(document.replacements.count) 条替换规则和 \(document.customWords.count) 个自定义词汇。

        "合并"将其添加到当前词典；"替换"会先清空当前词典再导入。
        """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "合并")
        confirm.addButton(withTitle: "替换")
        confirm.addButton(withTitle: "取消")

        switch confirm.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func deleteBoostTerm(at index: Int) {
        guard self.boostTerms.indices.contains(index) else { return }
        self.boostTerms.remove(at: index)
        self.saveBoostTerms()
    }

    private func deleteEntry(_ entry: SettingsStore.CustomDictionaryEntry) {
        self.entries.removeAll { $0.id == entry.id }
        self.saveEntries()
    }

    /// Returns all existing trigger words for duplicate detection
    private func allExistingTriggers(excluding entryId: UUID? = nil) -> Set<String> {
        var triggers = Set<String>()
        for entry in self.entries where entry.id != entryId {
            for trigger in entry.triggers {
                triggers.insert(trigger.lowercased())
            }
        }
        return triggers
    }

    private func existingBoostTerms(excludingIndex: Int? = nil) -> Set<String> {
        var terms: Set<String> = []
        for (index, term) in self.boostTerms.enumerated() where index != excludingIndex {
            terms.insert(term.text.lowercased())
        }
        return terms
    }
}

private struct EditableBoostTerm: Identifiable {
    let id = UUID()
    let index: Int
    let term: ParakeetVocabularyStore.VocabularyConfig.Term
}

private enum DictionaryComposerMode: CaseIterable, Identifiable {
    case train
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .train:
            return "语音训练"
        case .manual:
            return "手动添加"
        }
    }

    var systemImage: String {
        switch self {
        case .train:
            return "mic.fill"
        case .manual:
            return "keyboard"
        }
    }

    var detail: String {
        switch self {
        case .train:
            return "多说几遍，让 FluidVoice 捕捉其识别到的版本。"
        case .manual:
            return "输入误识别文本及您期望的正确拼写。"
        }
    }
}

private struct DictionaryComposerModeTab: View {
    let mode: DictionaryComposerMode
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: self.mode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(self.mode.title)
                    .font(self.theme.typography.bodySmallStrong)
            }
            .foregroundStyle(self.foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .background(self.background)
            .contentShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(self.isDisabled)
        .opacity(self.isDisabled ? 0.55 : 1)
        .onHover { hovering in
            guard !self.reduceMotion else {
                self.isHovered = hovering
                return
            }
            withAnimation(.easeOut(duration: 0.14)) {
                self.isHovered = hovering
            }
        }
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        self.isSelected ? Color.white : self.theme.palette.primaryText
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
            .fill(
                self.isSelected
                    ? self.theme.palette.accent
                    : (self.isHovered ? self.theme.palette.cardBackground.opacity(0.6) : Color.clear)
            )
    }
}

private enum CustomDictionaryManualEntry {
    static func parseTriggers(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

enum CustomDictionaryTrainingMerge {
    static let recommendedSamples = 5
    static let maxSamples = 20
    static let readyCoveredCount = 3

    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'“”‘’")

    static func normalizedReplacement(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedTrigger(_ value: String) -> String? {
        let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(self.edgePunctuation)
        let trimmed = value.trimmingCharacters(in: edgeCharacters).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedTriggers(from values: [String], intendedReplacement: String) -> [String] {
        let replacement = self.normalizedReplacement(intendedReplacement)
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(values.count)

        for value in values {
            guard let trigger = self.normalizedTrigger(value),
                  trigger.caseInsensitiveCompare(replacement) != .orderedSame,
                  !seen.contains(trigger)
            else {
                continue
            }
            seen.insert(trigger)
            result.append(trigger)
            if result.count >= self.maxSamples {
                break
            }
        }

        return result
    }

    static func mergedEntries(
        current entries: [SettingsStore.CustomDictionaryEntry],
        replacement: String,
        triggers: [String]
    ) -> [SettingsStore.CustomDictionaryEntry] {
        let replacementText = self.normalizedReplacement(replacement)
        let incomingTriggers = self.normalizedTriggers(from: triggers, intendedReplacement: replacementText)
        guard !replacementText.isEmpty, !incomingTriggers.isEmpty else { return entries }

        let matchingIndex = entries.firstIndex {
            $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame
        }
        let replacementID = matchingIndex.map { entries[$0].id }
        let storedReplacementText = matchingIndex.map { entries[$0].replacement } ?? replacementText
        let matchingEntries = entries.filter {
            $0.replacement.caseInsensitiveCompare(storedReplacementText) == .orderedSame
        }
        let existingTriggers = matchingEntries.flatMap(\.triggers)
        let combinedTriggers = self.normalizedTriggers(
            from: existingTriggers + incomingTriggers,
            intendedReplacement: storedReplacementText
        )
        let triggerKeys = Set(combinedTriggers)

        let mergedEntry = replacementID.map {
            SettingsStore.CustomDictionaryEntry(
                id: $0,
                triggers: combinedTriggers,
                replacement: storedReplacementText
            )
        } ?? SettingsStore.CustomDictionaryEntry(
            triggers: combinedTriggers,
            replacement: storedReplacementText
        )

        var didInsertMergedEntry = false
        var updatedEntries: [SettingsStore.CustomDictionaryEntry] = []
        updatedEntries.reserveCapacity(entries.count + (matchingIndex == nil ? 1 : 0))

        for entry in entries {
            if entry.replacement.caseInsensitiveCompare(storedReplacementText) == .orderedSame {
                if !didInsertMergedEntry {
                    updatedEntries.append(mergedEntry)
                    didInsertMergedEntry = true
                }
                continue
            }

            let remainingTriggers = entry.triggers.filter { trigger in
                guard let key = self.normalizedTrigger(trigger) else { return false }
                return !triggerKeys.contains(key)
            }
            guard !remainingTriggers.isEmpty else { continue }
            updatedEntries.append(
                SettingsStore.CustomDictionaryEntry(
                    id: entry.id,
                    triggers: remainingTriggers,
                    replacement: entry.replacement
                )
            )
        }

        if !didInsertMergedEntry {
            updatedEntries.insert(mergedEntry, at: 0)
        }

        return updatedEntries
    }
}

private struct ReplacementConfirmation: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

private struct ReplacementConfirmationToast: View {
    let confirmation: ReplacementConfirmation

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            ZStack {
                Circle()
                    .fill(self.theme.palette.accent.opacity(0.14))
                    .frame(width: 58, height: 58)

                Circle()
                    .stroke(self.theme.palette.accent.opacity(0.24), lineWidth: 1)
                    .frame(width: 58, height: 58)

                Image(systemName: "checkmark")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(self.theme.palette.accent)
            }

            VStack(spacing: 3) {
                Text(self.confirmation.title)
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(self.confirmation.detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 220)
        .padding(.horizontal, self.theme.metrics.spacing.xl)
        .padding(.vertical, self.theme.metrics.spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.3), lineWidth: 1)
                )
                .shadow(
                    color: self.theme.palette.accent.opacity(0.24),
                    radius: 24,
                    x: 0,
                    y: 10
                )
                .shadow(
                    color: Color.black.opacity(0.16),
                    radius: 18,
                    x: 0,
                    y: 8
                )
        )
        .accessibilityElement(children: .combine)
    }
}

private struct TrainingVariantChip: View {
    let number: Int
    let variant: String
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text("\(self.number)")
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.accent)
                .frame(minWidth: 11)

            Text(self.variant)
                .font(self.theme.typography.caption)
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: self.onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("移除 \(self.variant)")
        }
        .frame(maxWidth: 165)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

private struct DictionaryPreviewChip: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(self.text)
            .font(self.theme.typography.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(self.theme.palette.cardBackground.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                    )
            )
    }
}

private enum BoostStrengthPreset: String, CaseIterable, Identifiable {
    case mild = "Mild"
    case balanced = "Balanced"
    case strong = "Strong"

    var id: String { self.rawValue }

    var weight: Float {
        switch self {
        case .mild: return 5.0
        case .balanced: return 10.0
        case .strong: return 13.0
        }
    }

    var hint: String {
        switch self {
        case .mild: return "非常轻微的权重调整，影响极小。"
        case .balanced: return "适合大多数名称和产品词汇的默认选项。"
        case .strong: return "当需要在嘈杂音频中更频繁地识别此词时使用。"
        }
    }

    var badgeColor: Color {
        switch self {
        case .mild: return .blue
        case .balanced: return Color.fluidGreen
        case .strong: return .orange
        }
    }

    static func nearest(for weight: Float) -> Self {
        if weight < 8.5 { return .mild }
        if weight > 11.5 { return .strong }
        return .balanced
    }
}

// MARK: - Boost Term Row

struct BoostTermRow: View {
    let term: ParakeetVocabularyStore.VocabularyConfig.Term
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Text(self.term.text)
                .font(self.theme.typography.bodySmallStrong)

            Spacer()

            if let weight = self.term.weight {
                let strength = BoostStrengthPreset.nearest(for: weight)
                Text(strength.rawValue)
                    .font(self.theme.typography.bodySmallStrong)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(strength.badgeColor.opacity(0.25)))
                    .foregroundStyle(strength.badgeColor)
            }

            HStack(spacing: 2) {
                Button {
                    self.onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("配置 \(self.term.text)")

                Button(role: .destructive) {
                    self.onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle(foreground: .red, borderColor: .red))
                .help("删除 \(self.term.text)")
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

// MARK: - Add Boost Term Sheet

struct AddBoostTermSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingTerms: Set<String>
    let onSave: (ParakeetVocabularyStore.VocabularyConfig.Term) -> Void

    @State private var termText = ""
    @State private var strength: BoostStrengthPreset = .balanced

    private var normalizedTerm: String {
        self.termText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        self.existingTerms.contains(self.normalizedTerm.lowercased())
    }

    private var canSave: Bool {
        !self.normalizedTerm.isEmpty && !self.isDuplicate
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("添加自定义词汇")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("首选词汇或短语")
                        .font(.subheadline.weight(.medium))
                    TextField("FluidVoice", text: self.$termText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { self.saveIfValid() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("词汇优先级")
                        .font(.subheadline.weight(.medium))
                    Picker("词汇优先级", selection: self.$strength) {
                        ForEach(BoostStrengthPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(self.strength.hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if self.isDuplicate {
                    Text("该词汇已存在。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("取消") { self.dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("保存") { self.saveIfValid() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!self.canSave)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
        .frame(minHeight: 300, idealHeight: 340, maxHeight: 460)
        .onAppear {
            // Always start new entries at the recommended default.
            self.termText = ""
            self.strength = .balanced
        }
    }

    private func saveIfValid() {
        guard self.canSave else { return }
        self.onSave(
            ParakeetVocabularyStore.VocabularyConfig.Term(
                text: self.normalizedTerm,
                weight: self.strength.weight,
                aliases: []
            )
        )
        self.dismiss()
    }
}

// MARK: - Edit Boost Term Sheet

struct EditBoostTermSheet: View {
    @Environment(\.dismiss) private var dismiss

    let term: ParakeetVocabularyStore.VocabularyConfig.Term
    let existingTerms: Set<String>
    let onSave: (ParakeetVocabularyStore.VocabularyConfig.Term) -> Void

    @State private var termText = ""
    @State private var strength: BoostStrengthPreset = .balanced

    private var normalizedTerm: String {
        self.termText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        self.existingTerms.contains(self.normalizedTerm.lowercased())
    }

    private var canSave: Bool {
        !self.normalizedTerm.isEmpty && !self.isDuplicate
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("编辑自定义词汇")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred Word or Phrase")
                        .font(.subheadline.weight(.medium))
                    TextField("FluidVoice", text: self.$termText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { self.saveIfValid() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Word Priority")
                        .font(.subheadline.weight(.medium))
                    Picker("Word Priority", selection: self.$strength) {
                        ForEach(BoostStrengthPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(self.strength.hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if self.isDuplicate {
                    Text("This term already exists.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Cancel") { self.dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Save") { self.saveIfValid() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!self.canSave)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
        .frame(minHeight: 300, idealHeight: 340, maxHeight: 460)
        .onAppear {
            self.termText = self.term.text
            self.strength = BoostStrengthPreset.nearest(for: self.term.weight ?? BoostStrengthPreset.balanced.weight)
        }
    }

    private func saveIfValid() {
        guard self.canSave else { return }
        self.onSave(
            ParakeetVocabularyStore.VocabularyConfig.Term(
                text: self.normalizedTerm,
                weight: self.strength.weight,
                aliases: self.term.aliases
            )
        )
        self.dismiss()
    }
}

// MARK: - Dictionary Entry Row

struct DictionaryEntryRow: View {
    let entry: SettingsStore.CustomDictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.sm) {
            FlowLayout(spacing: 4) {
                ForEach(self.entry.triggers, id: \.self) { trigger in
                    Text(trigger)
                        .font(self.theme.typography.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)

            Text(self.entry.replacement)
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button {
                    self.onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("配置替换规则")

                Button(role: .destructive) {
                    self.onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle(foreground: .red, borderColor: .red))
                .help("删除替换规则")
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

// MARK: - Add Entry Sheet

struct AddDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let existingTriggers: Set<String>
    let onSave: (SettingsStore.CustomDictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""

    private var duplicateTriggers: [String] {
        self.parseTriggers().filter { self.existingTriggers.contains($0) }
    }

    private var canSave: Bool {
        !self.parseTriggers().isEmpty &&
            !self.replacement.trimmingCharacters(in: .whitespaces).isEmpty &&
            self.duplicateTriggers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("添加词典条目")
                    .font(.headline)
                Spacer()
                Button("取消") { self.dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider()

            // Triggers input
            VStack(alignment: .leading, spacing: 6) {
                Text("误识别词汇（触发词）")
                    .font(.subheadline.weight(.medium))
                Text("请输入以逗号分隔的词汇，这些是转录可能识别到的内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("fluid voice, fluid boys", text: self.$triggersText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }

                // Duplicate warning
                if !self.duplicateTriggers.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("重复的触发词：\(self.duplicateTriggers.joined(separator: ", "))")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            // Replacement input
            VStack(alignment: .leading, spacing: 6) {
                Text("正确拼写（替换）")
                    .font(.subheadline.weight(.medium))
                Text("这是最终出现在转录结果中的内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("FluidVoice", text: self.$replacement)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }
            }

            Spacer()

            // Preview
            if !self.triggersText.isEmpty && !self.replacement.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("预览")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(self.parseTriggers(), id: \.self) { trigger in
                            Text(trigger)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4).fill(
                                        self.duplicateTriggers.contains(trigger)
                                            ? AnyShapeStyle(Color.orange.opacity(0.3))
                                            : AnyShapeStyle(.quaternary)
                                    )
                                )
                        }

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(self.replacement)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(self.theme.palette.accent)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
            }

            // Save button
            HStack {
                Spacer()
                Button("添加替换") { self.saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .tint(self.theme.palette.accent)
                    .disabled(!self.canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 450, maxWidth: 500)
        .frame(minHeight: 350, idealHeight: 400, maxHeight: 450)
    }

    private func parseTriggers() -> [String] {
        self.triggersText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func saveIfValid() {
        guard self.canSave else { return }

        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: self.parseTriggers(),
            replacement: self.replacement.trimmingCharacters(in: .whitespaces)
        )
        self.onSave(entry)
        self.dismiss()
    }
}

// MARK: - Edit Entry Sheet

struct EditDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let entry: SettingsStore.CustomDictionaryEntry
    let existingTriggers: Set<String>
    let onSave: (SettingsStore.CustomDictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""

    private var duplicateTriggers: [String] {
        self.parseTriggers().filter { self.existingTriggers.contains($0) }
    }

    private var canSave: Bool {
        !self.parseTriggers().isEmpty &&
            !self.replacement.trimmingCharacters(in: .whitespaces).isEmpty &&
            self.duplicateTriggers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("编辑词典条目")
                    .font(.headline)
                Spacer()
                Button("Cancel") { self.dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider()

            // Triggers input
            VStack(alignment: .leading, spacing: 6) {
                Text("Misheard Words (triggers)")
                    .font(.subheadline.weight(.medium))
                Text("Enter words separated by commas. These are what the transcription might hear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("fluid voice, fluid boys", text: self.$triggersText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }

                // Duplicate warning
                if !self.duplicateTriggers.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Duplicate triggers: \(self.duplicateTriggers.joined(separator: ", "))")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            // Replacement input
            VStack(alignment: .leading, spacing: 6) {
                Text("Correct Spelling (replacement)")
                    .font(.subheadline.weight(.medium))
                Text("This is what will appear in the final transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("FluidVoice", text: self.$replacement)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }
            }

            Spacer()

            // Preview
            if !self.triggersText.isEmpty && !self.replacement.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(self.parseTriggers(), id: \.self) { trigger in
                            Text(trigger)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4).fill(
                                        self.duplicateTriggers.contains(trigger)
                                            ? AnyShapeStyle(Color.orange.opacity(0.3))
                                            : AnyShapeStyle(.quaternary)
                                    )
                                )
                        }

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(self.replacement)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(self.theme.palette.accent)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
            }

            // Save button
            HStack {
                Spacer()
                Button("保存更改") { self.saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .tint(self.theme.palette.accent)
                    .disabled(!self.canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 450, maxWidth: 500)
        .frame(minHeight: 320, idealHeight: 380, maxHeight: 420)
        .onAppear {
            self.triggersText = self.entry.triggers.joined(separator: ", ")
            self.replacement = self.entry.replacement
        }
    }

    private func parseTriggers() -> [String] {
        self.triggersText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func saveIfValid() {
        guard self.canSave else { return }

        let updatedEntry = SettingsStore.CustomDictionaryEntry(
            id: self.entry.id,
            triggers: self.parseTriggers(),
            replacement: self.replacement.trimmingCharacters(in: .whitespaces)
        )
        self.onSave(updatedEntry)
        self.dismiss()
    }
}
