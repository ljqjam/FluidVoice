//
//  WelcomeView.swift
//  fluid
//
//  Welcome and setup guide view
//

import AppKit
import AVFoundation
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject private var settings = SettingsStore.shared
    @Binding var selectedSidebarItem: SidebarItem?
    @Binding var playgroundUsed: Bool
    var isTranscriptionFocused: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme

    let accessibilityEnabled: Bool
    let stopAndProcessTranscription: () async -> Void
    let startRecording: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void

    private var commandModeShortcutDisplay: String {
        self.settings.commandModeHotkeyShortcut?.displayString ?? "Not set"
    }

    private var writeModeShortcutDisplay: String {
        self.settings.rewriteModeHotkeyShortcut.displayString
    }

    private let playgroundSectionID = "welcome-playground-section"

    private var commandModeColor: Color {
        self.theme.palette.warning
    }

    private var editModeColor: Color {
        self.theme.palette.accent
    }

    private var isAIEnhancementReady: Bool {
        DictationAIPostProcessingGate.isProviderConfigured()
    }

    private var appDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "book.fill")
                            .font(self.theme.typography.titleIcon)
                            .foregroundStyle(self.theme.palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((self.asr.isAsrReady || self.asr.modelsExistOnDisk) ? "开始使用" : "欢迎使用 FluidVoice")
                                .font(self.theme.typography.title)
                            Text("随时随地开口说，FluidVoice 自动为你输入。")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 4)

                    // Quick Setup Checklist
                    ThemedCard(style: .prominent) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Label("快速设置", systemImage: "checkmark.circle.fill")
                                    .font(self.theme.typography.sectionTitle)
                                    .foregroundStyle(self.theme.palette.accent)

                                Spacer()

                                Button {
                                    self.settings.resetOnboardingProgress()
                                    self.playgroundUsed = false
                                } label: {
                                    Label("重新运行新手引导", systemImage: "arrow.counterclockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                SetupStepView(
                                    step: 1,
                                    // Consider model step complete if ready OR downloaded (even if not loaded)
                                    title: (self.asr.isAsrReady || self.asr.modelsExistOnDisk) ? "语音模型已就绪" : "下载语音模型",
                                    description: self.asr.isAsrReady
                                        ? "语音识别模型已加载并就绪"
                                        : (
                                            self.asr.modelsExistOnDisk
                                                ? "模型已下载，将在需要时加载"
                                                : "下载离线语音转录 AI 模型（约 500MB）"
                                        ),
                                    status: (self.asr.isAsrReady || self.asr.modelsExistOnDisk) ? .completed : .pending,
                                    action: {
                                        self.selectedSidebarItem = .voiceEngine
                                    },
                                    actionButtonTitle: "前往语音引擎",
                                    showActionButton: !(self.asr.isAsrReady || self.asr.modelsExistOnDisk)
                                )

                                SetupStepView(
                                    step: 2,
                                    title: self.asr.micStatus == .authorized ? "麦克风权限已授予" : "授予麦克风权限",
                                    description: self.asr.micStatus == .authorized
                                        ? "FluidVoice 已获得麦克风访问权限"
                                        : "允许 FluidVoice 访问麦克风以进行语音输入",
                                    status: self.asr.micStatus == .authorized ? .completed : .pending,
                                    action: {
                                        if self.asr.micStatus == .notDetermined {
                                            self.asr.requestMicAccess()
                                        } else if self.asr.micStatus == .denied {
                                            self.asr.openSystemSettingsForMic()
                                        }
                                    },
                                    actionButtonTitle: self.asr.micStatus == .notDetermined ? "授权访问" : "打开设置",
                                    showActionButton: self.asr.micStatus != .authorized
                                )

                                SetupStepView(
                                    step: 3,
                                    title: self.accessibilityEnabled ? "无障碍访问已启用" : "启用无障碍访问",
                                    description: self.accessibilityEnabled
                                        ? "已授予无障碍权限，可向应用输入文字"
                                        : "如图所示，将 \(self.appDisplayName) 拖入无障碍应用列表",
                                    status: self.accessibilityEnabled ? .completed : .pending,
                                    action: {
                                        self.openAccessibilitySettings()
                                    },
                                    actionButtonTitle: "打开设置",
                                    showActionButton: !self.accessibilityEnabled
                                )

                                SetupStepView(
                                    step: 4,
                                    title: self.isAIEnhancementReady ? "AI 增强已配置" : "配置 AI 增强（可选）",
                                    description: self.isAIEnhancementReady
                                        ? "AI 文本增强功能已就绪"
                                        : "配置 API 密钥以启用 AI 文本增强",
                                    status: self.isAIEnhancementReady ? .completed : .pending,
                                    action: {
                                        self.selectedSidebarItem = .aiEnhancements
                                    },
                                    actionButtonTitle: "配置 AI"
                                )

                                SetupStepView(
                                    step: 5,
                                    title: self.playgroundUsed ? "设置测试成功" : "测试你的设置",
                                    description: self.playgroundUsed
                                        ? "你已成功测试语音转录"
                                        : "在下方的测试区试用，以验证完整设置",
                                    status: self.playgroundUsed ? .completed : .pending,
                                    action: {
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            proxy.scrollTo(self.playgroundSectionID, anchor: .top)
                                        }
                                        self.isTranscriptionFocused.wrappedValue = true
                                    },
                                    actionButtonTitle: "前往测试区",
                                    showActionButton: !self.playgroundUsed
                                )
                                .id("playground-step-\(self.playgroundUsed)")
                            }
                        }
                        .padding(14)
                    }

                    // Test Playground
                    ThemedCard(hoverEffect: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("测试区")
                                            .font(self.theme.typography.sectionTitle)
                                        Text("点击录制，开口说话，查看转录结果")
                                            .font(self.theme.typography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "text.bubble")
                                        .font(self.theme.typography.titleIcon)
                                }

                                Spacer()

                                if self.asr.isRunning {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 6, height: 6)
                                        Text("录音中...")
                                            .font(self.theme.typography.captionStrong)
                                            .foregroundStyle(.red)
                                    }
                                } else if !self.asr.finalText.isEmpty {
                                    Text("\(self.asr.finalText.count) 个字符")
                                        .font(self.theme.typography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if self.settings.selectedSpeechModel == .parakeetTDT || self.settings.selectedSpeechModel == .parakeetTDTv2 {
                                HStack(spacing: 6) {
                                    Image(systemName: "text.magnifyingglass")
                                        .font(self.theme.typography.caption)
                                        .foregroundStyle(self.theme.palette.accent)
                                    Text(self.asr.wordBoostStatusText)
                                        .font(self.theme.typography.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(self.theme.palette.contentBackground.opacity(0.6))
                                )
                            }

                            VStack(alignment: .leading, spacing: 14) {
                                // Recording Control — centered button
                                HStack {
                                    Spacer()
                                    Button {
                                        if self.asr.isRunning {
                                            Task {
                                                await self.stopAndProcessTranscription()
                                            }
                                        } else {
                                            self.startRecording()
                                            self.playgroundUsed = true
                                            SettingsStore.shared.playgroundUsed = true
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: self.asr.isRunning ? "stop.fill" : "mic.fill")
                                            Text(self.asr.isRunning ? "停止录音" : "开始录音")
                                        }
                                        .frame(maxWidth: 220)
                                    }
                                    .fluidButton(.primary, size: .large, isRecording: self.asr.isRunning)
                                    .buttonHoverEffect()
                                    .scaleEffect(!self.reduceMotion && self.asr.isRunning ? 1.02 : 1.0)
                                    .animation(self.reduceMotion ? nil : .spring(response: 0.3), value: self.asr.isRunning)
                                    .disabled(!self.asr.isAsrReady && !self.asr.isRunning)
                                    Spacer()
                                }

                                // Text Area
                                VStack(alignment: .leading, spacing: 8) {
                                    TextEditor(text: Binding(
                                        get: { self.asr.finalText },
                                        set: { self.asr.finalText = $0 }
                                    ))
                                    .font(self.theme.typography.body)
                                    .focused(self.isTranscriptionFocused)
                                    .frame(height: 120)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(
                                                self.asr.isRunning ? self.theme.palette.accent.opacity(0.06) : self.theme.palette.cardBackground
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(
                                                        self.asr.isRunning ? self.theme.palette.accent.opacity(0.4) : self.theme.palette.cardBorder.opacity(0.6),
                                                        lineWidth: self.asr.isRunning ? 2 : 1
                                                    )
                                            )
                                    )
                                    .scrollContentBackground(.hidden)
                                    .overlay(
                                        VStack(spacing: 8) {
                                            if self.asr.isRunning {
                                                Image(systemName: "waveform")
                                                    .font(self.theme.typography.titleIcon)
                                                    .foregroundStyle(self.theme.palette.accent)
                                                Text("Listening... Speak now!")
                                                    .font(self.theme.typography.bodySmallStrong)
                                                    .foregroundStyle(self.theme.palette.accent)
                                                Text("停止录音后将显示转录内容")
                                                    .font(self.theme.typography.caption)
                                                    .foregroundStyle(self.theme.palette.accent.opacity(0.7))
                                            } else if self.asr.finalText.isEmpty {
                                                Image(systemName: "text.bubble")
                                                    .font(self.theme.typography.titleIcon)
                                                    .foregroundStyle(.secondary.opacity(0.5))
                                                Text("按下录制按钮或快捷键以开始")
                                                    .font(self.theme.typography.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .allowsHitTesting(false)
                                    )

                                    if !self.asr.finalText.isEmpty {
                                        HStack(spacing: 8) {
                                            Button {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(self.asr.finalText, forType: .string)
                                            } label: {
                                                Label("复制文本", systemImage: "doc.on.doc")
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(self.theme.palette.accent)
                                            .controlSize(.small)

                                            Button("清除并重新测试") {
                                                self.asr.finalText = ""
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                    .id(self.playgroundSectionID)

                    // Secondary guidance
                    ThemedCard(style: .subtle) {
                        VStack(alignment: .leading, spacing: 12) {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 10) {
                                    self.howToStep(number: 1, title: "开始录音", description: "按下快捷键（默认：右 Option/Alt）或点击按钮")
                                    self.howToStep(number: 2, title: "清晰说话", description: "自然说话——安静环境效果最佳")
                                    self.howToStep(number: 3, title: "自动输入结果", description: "转录内容将自动输入到当前聚焦的应用中")
                                }
                                .padding(.top, 8)
                            } label: {
                                Label("使用方法", systemImage: "play.fill")
                                    .font(self.theme.typography.sectionTitle)
                                    .foregroundStyle(self.theme.palette.accent)
                            }

                            Divider().opacity(0.2)

                            DisclosureGroup {
                                self.commandModeGuide
                                    .padding(.top, 8)
                            } label: {
                                HStack(spacing: 8) {
                                    Label("命令模式", systemImage: "terminal.fill")
                                        .font(self.theme.typography.sectionTitle)
                                        .foregroundStyle(self.commandModeColor)
                                    self.featureBadge("New", color: self.commandModeColor)
                                    self.featureBadge("Alpha", color: self.commandModeColor.opacity(0.75))
                                }
                            }

                            Divider().opacity(0.2)

                            DisclosureGroup {
                                self.editModeGuide
                                    .padding(.top, 8)
                            } label: {
                                HStack(spacing: 8) {
                                    Label("编辑模式", systemImage: "pencil.and.outline")
                                        .font(self.theme.typography.sectionTitle)
                                        .foregroundStyle(self.editModeColor)
                                    self.featureBadge("New", color: self.editModeColor)
                                }
                            }
                        }
                        .padding(12)
                    }
                }
                .padding(16)
            }
        }
        .onAppear {
            // CRITICAL FIX: Refresh microphone and model status immediately on appear
            // This prevents the Quick Setup from showing stale status before ASRService.initialize() runs
            Task { @MainActor in
                // Check microphone status without triggering the full initialize() delay
                self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

                // Check if models exist on disk (async for accurate detection with AppleSpeechAnalyzerProvider)
                await self.asr.checkIfModelsExistAsync()
            }
        }
    }

    // MARK: - Helper Views

    private var commandModeGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("通过语音命令控制 Mac，执行终端命令、打开应用等。")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("打开") {
                    self.selectedSidebarItem = .commandMode
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("开始使用")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.commandModeColor)

                HStack(spacing: 4) {
                    Text("按下")
                    self.keyboardBadge(self.commandModeShortcutDisplay)
                    Text("打开后说出命令，再次按下发送。")
                }
                .font(self.theme.typography.caption)
                .foregroundStyle(.primary.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("示例")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.commandModeColor)
                self.commandModeExample(icon: "folder", text: "\"List files in my Downloads folder\"")
                self.commandModeExample(icon: "plus.rectangle.on.folder", text: "\"Create a folder called Projects on Desktop\"")
                self.commandModeExample(icon: "network", text: "\"What's my IP address?\"")
                self.commandModeExample(icon: "safari", text: "\"Open Safari\"")
            }

            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.commandModeColor)
                Text("AI 可能出错，请避免执行破坏性命令。")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editModeGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 驱动的编辑助手，通过语音撰写新内容或编辑选中文字。")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("打开 AI 设置") {
                    self.selectedSidebarItem = .aiEnhancements
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("创建新文本")
                        .font(self.theme.typography.bodySmallStrong)
                        .foregroundStyle(self.editModeColor)

                    HStack(spacing: 4) {
                        Text("按下")
                        self.keyboardBadge(self.writeModeShortcutDisplay)
                        Text("并说出你想写的内容。")
                    }
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.primary.opacity(0.8))

                    self.writeModeExample(text: "\"Write an email asking for time off\"")
                    self.writeModeExample(text: "\"Draft a thank you note\"")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("编辑选中文本")
                        .font(self.theme.typography.bodySmallStrong)
                        .foregroundStyle(self.editModeColor)

                    HStack(spacing: 4) {
                        Text("先选中文本，再按下")
                        self.keyboardBadge(self.writeModeShortcutDisplay)
                        Text("并说出你的指令。")
                    }
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.primary.opacity(0.8))

                    self.writeModeExample(text: "\"Make this more formal\"")
                    self.writeModeExample(text: "\"Fix grammar and spelling\"")
                    self.writeModeExample(text: "\"Summarize this\"")
                }
            }
        }
    }

    private func howToStep(number: Int, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(self.theme.palette.accent.opacity(0.15))
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodyStrong)
                Text(description)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func featureBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(self.theme.typography.badge)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func keyboardBadge(_ text: String) -> some View {
        Text(text)
            .font(self.theme.typography.captionStrong)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(self.theme.palette.cardBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func commandModeExample(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.commandModeColor.opacity(0.8))
                .frame(width: 14)
            Text(text)
                .font(self.theme.typography.caption)
                .foregroundStyle(.primary.opacity(0.8))
        }
    }

    private func writeModeExample(text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(self.editModeColor.opacity(0.6))
                .frame(width: 4, height: 4)
            Text(text)
                .font(self.theme.typography.caption)
                .foregroundStyle(.primary.opacity(0.8))
        }
    }
}

struct OnboardingFlowView: View {
    @EnvironmentObject var appServices: AppServices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject private var settings = SettingsStore.shared

    @Binding var currentStep: Int
    let accessibilityEnabled: Bool
    let accessibilitySetupInProgress: Bool
    let markAISkipped: () -> Void
    let finishOnboarding: () -> Void
    let finishOnboardingAtGettingStarted: () -> Void
    let openAIEnhancementSettingsFromOnboarding: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let menuBarManager: MenuBarManager
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    let theme: AppTheme

    @State private var selectedLanguageID = SettingsStore.shared.onboardingSelectedLanguageID
    @State private var selectedModelRouteID: String?
    @State private var hoveredLanguageID: String?
    @State private var hoveredModelRouteID: String?
    @State private var hoveredModelActionButtonID: String?
    @State private var hoveredPermissionButtonID: String?
    @State private var hoveredFooterButton: OnboardingFooterButton?
    @State private var isShowingAllLanguages = false
    @State private var isShowingOtherModelRoutes = false
    @State private var preparingModelRouteID: String?
    @State private var uninstallingModelRouteID: String?
    @State private var modelPreparationTask: Task<Void, Never>?
    @State private var languageSearchText = ""
    @FocusState private var isLanguageSearchFocused: Bool
    @State private var hasPlayedLandingWelcomeSound = false
    @State private var landingGlowCenter = UnitPoint(x: 0.5, y: 0.18)
    @State private var lastLandingGlowLocation = CGPoint(x: -1000, y: -1000)
    private let landingGlowMovementThreshold: CGFloat = 24

    private enum OnboardingFooterButton {
        case back
        case skip
        case next
    }

    private enum OnboardingPillButtonTone {
        case primary
        case secondary
        case destructive
    }

    private struct OnboardingPillButtonConfiguration {
        let title: String
        let systemImage: String?
        let tone: OnboardingPillButtonTone
        let width: CGFloat?
        let height: CGFloat
        let fontSize: CGFloat
        let iconSize: CGFloat
        let isHovered: Bool
        let isEnabled: Bool
    }

    private enum Step: Int, CaseIterable {
        case landing = 0
        case language = 1
        case voiceModel = 2
        case permissions = 3
        case playground = 4
        case aiEnhancement = 5

        var title: String {
            switch self {
            case .landing:
                return "欢迎"
            case .language:
                return "选择语言"
            case .voiceModel:
                return "选择语音引擎"
            case .permissions:
                return "启用访问权限"
            case .aiEnhancement:
                return "配置 AI 增强"
            case .playground:
                return "试用 FluidVoice"
            }
        }

        var subtitle: String {
            switch self {
            case .landing:
                return "随时随地开口说，FluidVoice 自动为你输入。"
            case .language:
                return "选择你最常用的语言。"
            case .voiceModel:
                return "为你的语言选择最合适的本地引擎。"
            case .permissions:
                return "允许 FluidVoice 聆听并向其他应用输入文字。"
            case .aiEnhancement:
                return "可选：配置 AI 后处理，或跳过此步骤。"
            case .playground:
                return "完成设置前，请先使用一次听写快捷键。"
            }
        }
    }

    private var step: Step {
        Step(rawValue: self.currentStep) ?? .voiceModel
    }

    private var progressValue: Double {
        Double(self.step.rawValue) / Double(Step.allCases.count - 1)
    }

    private var compactProgressValue: Double {
        Double(self.step.rawValue + 1) / Double(Step.allCases.count)
    }

    private var popularOnboardingLanguages: [VoiceEngineLanguage] {
        VoiceEngineLanguageCatalog.popularLanguages()
    }

    private var selectedOnboardingLanguage: VoiceEngineLanguage {
        VoiceEngineLanguageCatalog.language(id: self.selectedLanguageID)
            ?? VoiceEngineLanguageCatalog.language(id: "en")
            ?? VoiceEngineLanguage(id: "en", displayName: "English", aliases: [], isPopular: true)
    }

    private var searchedOnboardingLanguages: [VoiceEngineLanguage] {
        VoiceEngineLanguageCatalog.searchableLanguages(query: self.languageSearchText)
    }

    private var selectedLanguageRoutes: [VoiceEngineLanguageRoute] {
        VoiceEngineLanguageCatalog.routes(for: self.selectedOnboardingLanguage)
    }

    private var selectedOnboardingRoute: VoiceEngineLanguageRoute? {
        if let selectedModelRouteID,
           let selectedRoute = self.selectedLanguageRoutes.first(where: { $0.id == selectedModelRouteID })
        {
            return selectedRoute
        }

        if let selectedRoute = self.selectedLanguageRoutes.first(where: { self.isRouteSelectedInSettings($0) }) {
            return selectedRoute
        }

        return self.selectedLanguageRoutes.first
    }

    private var primaryDisplayedModelRoute: VoiceEngineLanguageRoute? {
        self.selectedLanguageRoutes.first
    }

    private var defaultDisplayedModelRoutes: [VoiceEngineLanguageRoute] {
        var routes: [VoiceEngineLanguageRoute] = []
        if let primaryDisplayedModelRoute {
            routes.append(primaryDisplayedModelRoute)
        }
        if let builtInRoute = self.defaultBuiltInModelRoute,
           !routes.contains(where: { $0.id == builtInRoute.id })
        {
            routes.append(builtInRoute)
        }
        return routes
    }

    private var defaultBuiltInModelRoute: VoiceEngineLanguageRoute? {
        guard self.selectedOnboardingLanguage.id == "en" else {
            return nil
        }

        return self.selectedLanguageRoutes.first { route in
            switch route.model {
            case .appleSpeech, .appleSpeechAnalyzer:
                return true
            default:
                return false
            }
        }
    }

    private var otherModelRoutes: [VoiceEngineLanguageRoute] {
        let defaultRouteIDs = Set(self.defaultDisplayedModelRoutes.map(\.id))
        return self.selectedLanguageRoutes.filter { !defaultRouteIDs.contains($0.id) }
    }

    private var recommendedOnboardingModel: SettingsStore.SpeechModel {
        self.selectedOnboardingRoute?.model ?? SettingsStore.SpeechModel.defaultModel
    }

    private var recommendedModelReasonText: String {
        "适合 \(self.selectedOnboardingLanguage.displayName) 的推荐引擎，如需更多选项可查看。"
    }

    private var isRecommendedModelDownloaded: Bool {
        self.isOnboardingModelDownloaded(self.recommendedOnboardingModel)
    }

    private var isPreparingRecommendedModel: Bool {
        self.isPreparingOnboardingModel(self.recommendedOnboardingModel)
    }

    private var isRecommendedModelReady: Bool {
        self.isOnboardingModelReady(self.recommendedOnboardingModel)
    }

    private var isVoiceModelReady: Bool {
        guard let route = self.selectedOnboardingRoute else {
            return false
        }
        return self.isOnboardingRouteReady(route)
    }

    private var isModelPreparationInProgress: Bool {
        guard self.step == .voiceModel else {
            return false
        }
        return self.preparingModelRouteID != nil
            || self.asr.hasActiveModelPreparation
            || self.asr.isCancellingModelPreparation
            || self.asr.isDownloadingModel
            || (self.asr.isLoadingModel && !self.asr.isAsrReady)
    }

    private var isMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    private var isAccessibilityReady: Bool {
        self.accessibilityEnabled
    }

    private var isPermissionsReady: Bool {
        self.isMicrophoneReady && self.isAccessibilityReady
    }

    private var isAIReady: Bool {
        self.settings.onboardingAISkipped || DictationAIPostProcessingGate.isProviderConfigured()
    }

    private var isPlaygroundReady: Bool {
        self.settings.onboardingPlaygroundValidated || self.settings.onboardingPlaygroundSkipped
    }

    private var onboardingShortcutDisplay: String {
        let display = self.settings.primaryDictationShortcutDisplayString.trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? "your shortcut" : display
    }

    private var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    private var isRecordingPrimaryShortcut: Bool {
        self.activeShortcutRecordingTarget?.isPrimaryDictation == true
    }

    private var canContinue: Bool {
        guard !self.isModelPreparationInProgress else {
            return false
        }

        switch self.step {
        case .landing:
            return true
        case .language:
            return !self.selectedLanguageRoutes.isEmpty
        case .voiceModel:
            return self.isVoiceModelReady
        case .permissions:
            return self.isPermissionsReady
        case .aiEnhancement:
            return self.isAIReady
        case .playground:
            return self.isPlaygroundReady && !self.asr.isRunning && !self.isRecordingAnyShortcut
        }
    }

    private var primaryButtonTitle: String {
        switch self.step {
        case .landing:
            return "下一步"
        case .language:
            return "继续"
        case .aiEnhancement:
            return "完成设置"
        default:
            return "继续"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .background {
            ZStack {
                self.theme.palette.windowBackground
                    .opacity(0.98)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(self.theme.materials.window)
                    .opacity(0.75)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            self.syncOnboardingSelectionFromSettings()
            self.playLandingWelcomeSoundIfNeeded()
            Task { @MainActor in
                self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                await self.asr.checkIfModelsExistAsync()
            }
        }
        .onChange(of: self.currentStep) { _, _ in
            if self.step != .voiceModel {
                self.cancelOnboardingModelPreparation()
            }
            self.playLandingWelcomeSoundIfNeeded()
        }
        .onDisappear {
            self.cancelOnboardingModelPreparation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.syncOnboardingSelectionFromSettings()
            self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("欢迎使用 FluidVoice")
                .font(self.theme.typography.title)
                .foregroundStyle(self.theme.palette.primaryText)

            Text(self.step.subtitle)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)

            HStack {
                Text("第 \(self.step.rawValue + 1) 步，共 \(Step.allCases.count) 步")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(self.step.title)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accent)
            }

            ProgressView(value: self.progressValue)
                .tint(self.theme.palette.accent)
        }
        .padding(24)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch self.step {
        case .landing:
            self.landingStep
        case .language:
            self.languageStep
        case .voiceModel:
            self.voiceModelStep
        case .permissions:
            self.permissionsStep
        case .aiEnhancement:
            self.aiEnhancementStep
        case .playground:
            self.playgroundStep
        }
    }

    private var landingStep: some View {
        GeometryReader { proxy in
            let landing = self.theme.metrics.onboardingSurface.landing

            ZStack {
                VStack(alignment: .center, spacing: self.theme.metrics.onboardingSurface.landing.sectionSpacing) {
                    FluidOnboardingLandingHero(
                        eyebrow: "",
                        title: "开口说话。",
                        accentTitle: "剩下的交给我们。",
                        firstDetail: "精准。快速。私密。免费。",
                        secondDetail: "专为创作者、思考者和构建者打造。"
                    ) {
                        FluidOnboardingLandingPrimaryButton(title: "下一步") {
                            self.goNext()
                        }
                        .frame(
                            width: FluidOnboardingLandingPrimaryButton.size.width,
                            height: FluidOnboardingLandingPrimaryButton.size.height
                        )
                    }
                }
                .frame(width: landing.contentWidth, alignment: .center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .offset(y: -78)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
                .zIndex(-1)
            }
            .background {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)
            }
        }
    }

    private func updateLandingGlow(location: CGPoint, in size: CGSize) {
        guard !self.reduceMotion else { return }
        guard location.x.isFinite, location.y.isFinite, size.width > 0, size.height > 0 else { return }

        let dx = location.x - self.lastLandingGlowLocation.x
        let dy = location.y - self.lastLandingGlowLocation.y
        guard (dx * dx) + (dy * dy) > (self.landingGlowMovementThreshold * self.landingGlowMovementThreshold) else { return }

        self.lastLandingGlowLocation = location
        let normalizedX = min(max(location.x / size.width, 0), 1)
        let normalizedY = min(max(location.y / size.height, 0), 1)

        withAnimation(.easeOut(duration: 0.22)) {
            self.landingGlowCenter = UnitPoint(x: normalizedX, y: normalizedY)
        }
    }

    private func resetLandingGlow() {
        guard !self.reduceMotion else { return }
        self.lastLandingGlowLocation = CGPoint(x: -1000, y: -1000)

        withAnimation(.easeOut(duration: 0.35)) {
            self.landingGlowCenter = UnitPoint(x: 0.5, y: 0.18)
        }
    }

    private func playLandingWelcomeSoundIfNeeded() {
        guard self.step == .landing, !self.hasPlayedLandingWelcomeSound else { return }
        self.hasPlayedLandingWelcomeSound = true
        OnboardingSoundPlayer.shared.playWelcomeSound()
    }

    private var languageStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("你最常用\n哪种语言？")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.bottom, 18)

                            Text("我们将为你推荐最合适的语音引擎。")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 26)

                            LazyVGrid(
                                columns: [
                                    GridItem(.fixed(166), spacing: 16),
                                    GridItem(.fixed(166), spacing: 16),
                                    GridItem(.fixed(166), spacing: 16),
                                ],
                                spacing: 16
                            ) {
                                ForEach(self.popularOnboardingLanguages) { language in
                                    self.languageChoiceCard(for: language)
                                }

                                self.otherLanguageCard
                            }
                            .frame(width: 530)

                            if self.isShowingAllLanguages {
                                self.allLanguagesPicker
                                    .padding(.top, 18)
                            }

                            Text("你可以稍后在语音引擎设置中更改。")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .padding(.top, 18)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "继续",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private func languageChoiceCard(for language: VoiceEngineLanguage) -> some View {
        let isSelected = self.selectedLanguageID == language.id
        let isHovered = self.hoveredLanguageID == language.id
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let cardFillOpacity = isSelected
            ? (isHovered ? 0.15 : 0.075)
            : (isHovered ? 0.10 : 0.04)
        let borderColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 1 : 0.92)
            : (isHovered ? FluidOnboardingLandingColors.blue.opacity(0.58) : Color.white.opacity(0.10))
        let borderWidth: CGFloat = isSelected
            ? (isHovered ? 1.8 : 1.4)
            : (isHovered ? 1.2 : 1)
        let shadowColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.36 : 0.18)
            : FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.18 : 0)
        let shadowRadius: CGFloat = isSelected
            ? (isHovered ? 24 : 18)
            : (isHovered ? 20 : 14)

        return Button {
            self.selectOnboardingLanguage(language)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? FluidOnboardingLandingColors.blue : Color.white.opacity(0.72))
                    .frame(width: 22)

                Text(language.popularDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(FluidOnboardingLandingColors.blue)
                }
            }
            .padding(.horizontal, 15)
            .frame(width: 166, height: 58)
            .background(
                shape
                    .fill(Color.white.opacity(cardFillOpacity))
                    .overlay(
                        shape.stroke(
                            borderColor,
                            lineWidth: borderWidth
                        )
                    )
            )
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered in
            if isHovered {
                self.setHoveredLanguage(language.id)
            } else if self.hoveredLanguageID == language.id {
                self.setHoveredLanguage(nil)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    self.selectOnboardingLanguage(language)
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.displayName)
        .accessibilityValue(isSelected ? "已选择" : "")
    }

    private var otherLanguageCard: some View {
        let isSelected = !self.selectedOnboardingLanguage.isPopular
        let isHovered = self.hoveredLanguageID == "other"
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let fillOpacity = isSelected
            ? (isHovered ? 0.15 : 0.075)
            : (isHovered ? 0.10 : 0.04)
        let borderColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 1 : 0.92)
            : (isHovered ? FluidOnboardingLandingColors.blue.opacity(0.58) : Color.white.opacity(self.isShowingAllLanguages ? 0.16 : 0.10))
        let shadowColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.36 : 0.18)
            : FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.18 : 0)

        return Button {
            self.toggleAllLanguagesPicker()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isSelected ? FluidOnboardingLandingColors.blue : Color.white.opacity(self.isShowingAllLanguages ? 0.78 : 0.72))
                    .frame(width: 22)

                Text(isSelected ? self.selectedOnboardingLanguage.displayName : "其他")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)

                Spacer(minLength: 0)

                Image(systemName: self.isShowingAllLanguages ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.46))
            }
            .padding(.horizontal, 15)
            .frame(width: 166, height: 58)
            .background(
                shape
                    .fill(Color.white.opacity(fillOpacity))
                    .overlay(
                        shape.stroke(
                            borderColor,
                            lineWidth: isSelected ? 1.4 : 1
                        )
                    )
            )
            .shadow(color: shadowColor, radius: isSelected ? (isHovered ? 24 : 18) : 20, x: 0, y: 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered in
            self.setHoveredLanguage(isHovered ? "other" : nil)
        }
        .accessibilityLabel("其他语言")
        .accessibilityValue(self.isShowingAllLanguages ? "已展开" : "已折叠")
    }

    private var allLanguagesPicker: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.48))

                TextField(
                    "",
                    text: self.$languageSearchText,
                    prompt: Text("搜索支持的语言")
                        .foregroundStyle(Color.white.opacity(0.42))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .focused(self.$isLanguageSearchFocused)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(width: 530, height: 38)
            .contentShape(Rectangle())
            .onTapGesture {
                self.isLanguageSearchFocused = true
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) {
                    ForEach(self.searchedOnboardingLanguages) { language in
                        self.languageSearchRow(for: language)
                    }
                }
                .padding(8)
            }
            .frame(width: 530, height: 156)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    private func languageSearchRow(for language: VoiceEngineLanguage) -> some View {
        let isSelected = self.selectedLanguageID == language.id

        return Button {
            self.selectOnboardingLanguage(language)
        } label: {
            HStack(spacing: 10) {
                Text(language.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(FluidOnboardingLandingColors.blue)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? FluidOnboardingLandingColors.blue.opacity(0.14) : Color.white.opacity(0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func cinematicFooter(
        continueTitle: String,
        canContinue: Bool,
        continueAction: @escaping () -> Void,
        skipTitle: String? = nil,
        canSkip: Bool = false,
        skipAction: (() -> Void)? = nil
    ) -> some View {
        let canNavigateBack = !self.isModelPreparationInProgress && !self.asr.isRunning && !self.isRecordingAnyShortcut

        return HStack {
            self.cinematicFooterButton(
                title: "返回",
                kind: .back,
                isEnabled: canNavigateBack
            ) {
                self.goBack()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let skipTitle, let skipAction {
                self.cinematicFooterButton(
                    title: skipTitle,
                    kind: .skip,
                    isEnabled: canSkip
                ) {
                    skipAction()
                }
            }

            self.cinematicFooterButton(
                title: continueTitle,
                kind: .next,
                isEnabled: canContinue
            ) {
                continueAction()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 24)
    }

    private func cinematicFooterButton(
        title: String,
        kind: OnboardingFooterButton,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isPrimary = kind == .next
        let isHovered = self.hoveredFooterButton == kind && isEnabled

        return self.onboardingPillButton(
            configuration: OnboardingPillButtonConfiguration(
                title: title,
                systemImage: nil,
                tone: isPrimary ? .primary : .secondary,
                width: 132,
                height: 48,
                fontSize: 16,
                iconSize: 14,
                isHovered: isHovered,
                isEnabled: isEnabled
            ),
            action: action
        ) { isHovered in
            self.setHoveredFooterButton(isHovered ? kind : nil)
        }
        .accessibilityLabel(title)
    }

    private func setHoveredFooterButton(_ button: OnboardingFooterButton?) {
        guard self.hoveredFooterButton != button else { return }
        if self.reduceMotion {
            self.hoveredFooterButton = button
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredFooterButton = button
            }
        }
    }

    private func setHoveredLanguage(_ languageID: String?) {
        guard self.hoveredLanguageID != languageID else { return }
        if self.reduceMotion {
            self.hoveredLanguageID = languageID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredLanguageID = languageID
            }
        }
    }

    private func toggleAllLanguagesPicker() {
        if self.isShowingAllLanguages {
            self.isShowingAllLanguages = false
            self.isLanguageSearchFocused = false
            self.languageSearchText = ""
        } else {
            self.isShowingAllLanguages = true
            self.isLanguageSearchFocused = true
        }
    }

    private func selectOnboardingLanguage(_ language: VoiceEngineLanguage) {
        guard self.selectedLanguageID != language.id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = language.id
            self.settings.onboardingSelectedLanguageID = language.id
            self.selectedModelRouteID = VoiceEngineLanguageCatalog.routes(for: language).first?.id
            self.isShowingOtherModelRoutes = false
            self.isLanguageSearchFocused = false
            if language.isPopular {
                self.isShowingAllLanguages = false
                self.languageSearchText = ""
            }
            self.resetTryoutValidationForSetupChange()
        }
    }

    private func syncOnboardingSelectionFromSettings() {
        let allRoutes = VoiceEngineLanguageCatalog.allLanguages()
            .flatMap { VoiceEngineLanguageCatalog.routes(for: $0) }

        let storedLanguageID = self.settings.onboardingSelectedLanguageID
        let storedLanguageRoutes = VoiceEngineLanguageCatalog.routes(forLanguageID: storedLanguageID)
        let route = storedLanguageRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        } ?? storedLanguageRoutes.first ?? allRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        }

        guard let route else {
            if self.selectedModelRouteID == nil {
                self.selectedModelRouteID = self.selectedLanguageRoutes.first?.id
            }
            return
        }

        guard self.selectedLanguageID != route.language.id || self.selectedModelRouteID != route.id else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = route.language.id
            self.selectedModelRouteID = route.id
            self.isShowingOtherModelRoutes = false
            self.languageSearchText = ""
            self.isLanguageSearchFocused = false
        }
    }

    private var voiceModelStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: self.isShowingOtherModelRoutes) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("选择你的\n语音引擎")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 16)

                            Text(self.recommendedModelReasonText)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 14)

                            Text(self.selectedOnboardingLanguage.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FluidOnboardingLandingColors.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(FluidOnboardingLandingColors.blue.opacity(0.12))
                                        .overlay(Capsule().stroke(FluidOnboardingLandingColors.blue.opacity(0.24), lineWidth: 1))
                                )
                                .padding(.bottom, 18)

                            VStack(spacing: 10) {
                                let defaultRoutes = self.defaultDisplayedModelRoutes
                                if defaultRoutes.count == 1, let route = defaultRoutes.first {
                                    self.onboardingRouteCard(for: route)
                                } else if !defaultRoutes.isEmpty {
                                    HStack(spacing: 16) {
                                        ForEach(defaultRoutes) { route in
                                            self.onboardingRouteCard(for: route)
                                        }
                                    }
                                }

                                if !self.otherModelRoutes.isEmpty {
                                    self.otherModelRoutesToggleButton
                                }

                                if self.isShowingOtherModelRoutes {
                                    LazyVGrid(
                                        columns: [
                                            GridItem(.fixed(292), spacing: 16, alignment: .top),
                                            GridItem(.fixed(292), spacing: 16, alignment: .top),
                                        ],
                                        spacing: 16
                                    ) {
                                        ForEach(self.otherModelRoutes) { route in
                                            self.onboardingRouteCard(for: route, enablesHover: false)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .frame(width: 608)

                            if self.isModelPreparationInProgress {
                                Label("首次设置可能需要几分钟。等待过久？取消后重试。", systemImage: "clock.arrow.circlepath")
                                    .font(self.theme.typography.captionStrong)
                                    .foregroundStyle(Color.white.opacity(0.58))
                                    .labelStyle(.titleAndIcon)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.06))
                                            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                                    )
                                    .padding(.top, 14)
                            }

                            Text("你可以稍后在语音引擎设置中切换模型。")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .padding(.top, self.isModelPreparationInProgress ? 8 : 18)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "继续",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var permissionsStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("允许 FluidVoice\n聆听并输入")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.bottom, 16)

                            Text("只需两项权限，即可在任何地方使用听写。")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 28)

                            VStack(spacing: 14) {
                                self.permissionRow(
                                    stepNumber: 1,
                                    title: self.isMicrophoneReady ? "麦克风已就绪" : "允许使用麦克风",
                                    subtitle: self.isMicrophoneReady
                                        ? "FluidVoice 可以听到你的听写内容。"
                                        : "macOS 将请求一次授权，点击允许即可开始听写。",
                                    systemImage: "mic.fill",
                                    isReady: self.isMicrophoneReady,
                                    actionTitle: self.microphoneActionButtonTitle
                                ) {
                                    self.handleMicrophoneAction()
                                }

                                self.permissionRow(
                                    stepNumber: 2,
                                    title: self.accessibilityPermissionTitle,
                                    subtitle: self.accessibilityPermissionSubtitle,
                                    systemImage: "keyboard.fill",
                                    isReady: self.isAccessibilityReady,
                                    statusTitle: self.accessibilityPermissionStatusTitle,
                                    actionTitle: self.accessibilityPermissionActionTitle
                                ) {
                                    self.openAccessibilitySettings()
                                }

                                if !self.isAccessibilityReady {
                                    Text("已经启用了？macOS 确认权限后 FluidVoice 将自动更新。")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.42))
                                        .padding(.top, 2)
                                }
                            }
                            .frame(width: 560)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "继续",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var aiEnhancementStep: some View {
        OnboardingAIEnhancementStepView(
            finalText: Binding(
                get: { self.asr.finalText },
                set: { self.asr.finalText = $0 }
            ),
            progressValue: self.compactProgressValue,
            glowCenter: self.landingGlowCenter,
            language: self.selectedOnboardingLanguage,
            shortcutDisplay: self.onboardingShortcutDisplay,
            isTestReady: self.isPlaygroundReady,
            isRunning: self.asr.isRunning,
            isRecordingShortcut: self.isRecordingPrimaryShortcut,
            shortcutRecordingMessage: self.isRecordingPrimaryShortcut ? self.shortcutRecordingMessage : nil,
            onGlowMove: self.updateLandingGlow(location:in:),
            onGlowExit: self.resetLandingGlow,
            onBack: self.goBack,
            onSkip: {
                self.markAISkipped()
                self.finishOnboardingAtGettingStarted()
            },
            onUseAIProvider: self.openAIEnhancementSettingsFromOnboarding,
            onFinishSetup: self.finishOnboardingAtGettingStarted
        )
    }

    private var playgroundStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("FluidVoice 已就绪。")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.74)
                                .padding(.horizontal, 32)
                                .padding(.bottom, 14)

                            Text("现在来试用一下。")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 28)

                            OnboardingTryoutStepView(
                                finalText: Binding(
                                    get: { self.asr.finalText },
                                    set: { self.asr.finalText = $0 }
                                ),
                                language: self.selectedOnboardingLanguage,
                                shortcutDisplay: self.onboardingShortcutDisplay,
                                isReady: self.isPlaygroundReady,
                                isRunning: self.asr.isRunning,
                                isRecordingShortcut: self.isRecordingPrimaryShortcut,
                                shortcutRecordingMessage: self.isRecordingPrimaryShortcut ? self.shortcutRecordingMessage : nil,
                                onToggleShortcut: self.togglePrimaryShortcutRecording
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "继续",
                        canContinue: self.canContinue,
                        continueAction: {
                            self.handlePrimaryAction()
                        },
                        skipTitle: "跳过",
                        canSkip: !self.asr.isRunning && !self.isRecordingAnyShortcut,
                        skipAction: {
                            self.settings.onboardingPlaygroundSkipped = true
                            self.goNext()
                        }
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var microphoneActionButtonTitle: String {
        switch self.asr.micStatus {
        case .notDetermined:
            return "允许"
        case .denied, .restricted:
            return "打开设置"
        default:
            return "允许"
        }
    }

    private var accessibilityPermissionTitle: String {
        if self.isAccessibilityReady {
            return "文字输入权限已就绪"
        }
        return self.accessibilitySetupInProgress ? "完成无障碍访问设置" : "启用无障碍访问"
    }

    private var accessibilityPermissionSubtitle: String {
        if self.isAccessibilityReady {
            return "\(self.appDisplayName) can place text into the app you're using."
        }
        if self.accessibilitySetupInProgress {
            return "使用浮动引导，将 \(self.appDisplayName) 拖入无障碍应用列表。"
        }
        return "打开设置，然后使用浮动引导添加 \(self.appDisplayName)。"
    }

    private var appDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    private var accessibilityPermissionStatusTitle: String {
        if self.isAccessibilityReady {
            return "已就绪"
        }
        return self.accessibilitySetupInProgress ? "设置中" : "需要设置"
    }

    private var accessibilityPermissionActionTitle: String {
        self.accessibilitySetupInProgress ? "显示引导" : "打开设置"
    }

    private var otherModelRoutesToggleButton: some View {
        Button {
            self.toggleOtherModelRoutes()
        } label: {
            HStack(spacing: 6) {
                Text(self.isShowingOtherModelRoutes ? "隐藏其他模型" : "显示其他模型")

                Image(systemName: self.isShowingOtherModelRoutes ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.62))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.025))
                    .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(self.isShowingOtherModelRoutes ? "隐藏其他模型" : "显示其他模型")
    }

    private func toggleOtherModelRoutes() {
        self.isShowingOtherModelRoutes.toggle()
    }

    private func isOnboardingModelSelected(_ model: SettingsStore.SpeechModel) -> Bool {
        self.settings.selectedSpeechModel == model
    }

    private func isOnboardingModelReady(_ model: SettingsStore.SpeechModel) -> Bool {
        self.isOnboardingModelSelected(model) && self.asr.isAsrReady
    }

    private func isOnboardingRouteReady(_ route: VoiceEngineLanguageRoute) -> Bool {
        self.isRouteSelectedInSettings(route) && self.asr.isAsrReady
    }

    private func isOnboardingModelDownloaded(_ model: SettingsStore.SpeechModel) -> Bool {
        self.isOnboardingModelBundledOrInstalled(model) || (self.isOnboardingModelSelected(model) && (self.asr.isAsrReady || self.asr.modelsExistOnDisk))
    }

    private func isOnboardingModelBundledOrInstalled(_ model: SettingsStore.SpeechModel) -> Bool {
        model.isInstalled
    }

    private func isPreparingOnboardingModel(_ model: SettingsStore.SpeechModel) -> Bool {
        self.isOnboardingModelSelected(model) && (self.asr.isDownloadingModel || (self.asr.isLoadingModel && !self.asr.isAsrReady))
    }

    private func onboardingModelActionButtonTitle(isPreparing: Bool, isDownloaded: Bool, isReady: Bool) -> String {
        if isPreparing {
            return self.asr.isLoadingModel ? "加载中..." : "下载中..."
        }
        if isReady {
            return "当前已激活"
        }
        if isDownloaded {
            return "激活"
        }
        return "下载并激活"
    }

    private func prepareOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        guard !self.asr.isRunning, !self.isModelPreparationInProgress, self.uninstallingModelRouteID == nil else { return }

        self.modelPreparationTask?.cancel()
        self.preparingModelRouteID = route.id
        self.selectOnboardingRoute(route)

        self.modelPreparationTask = Task { @MainActor in
            defer {
                self.preparingModelRouteID = nil
                self.modelPreparationTask = nil
            }

            do {
                try await self.asr.ensureAsrReady()
            } catch is CancellationError {
                DebugLogger.shared.info("Cancelled onboarding voice model setup for \(route.model.displayName)", source: "OnboardingFlowView")
            } catch {
                DebugLogger.shared.error("Failed to prepare onboarding voice model \(route.model.displayName): \(error)", source: "OnboardingFlowView")
                // Surface the failure in the UI instead of only logging it, so the user
                // isn't stuck at a disabled button. The shared ContentView alert (bound to
                // asr.showError) presents this during onboarding. See #355.
                self.asr.errorTitle = "Voice Model Setup Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
            guard !Task.isCancelled else { return }
            await self.asr.checkIfModelsExistAsync()
        }
    }

    private func cancelOnboardingModelPreparation() {
        self.modelPreparationTask?.cancel()
        self.asr.cancelModelPreparation()
    }

    private func uninstallOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        guard !self.asr.isRunning, !self.isModelPreparationInProgress, self.uninstallingModelRouteID == nil else { return }

        self.uninstallingModelRouteID = route.id

        Task { @MainActor in
            defer {
                self.uninstallingModelRouteID = nil
            }

            do {
                try await self.asr.clearModelCache(for: route.model)
                await self.asr.checkIfModelsExistAsync()
            } catch {
                DebugLogger.shared.error("Failed to delete onboarding voice model \(route.model.displayName): \(error)", source: "OnboardingFlowView")
                self.asr.errorTitle = "Model Delete Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    private func onboardingRouteCard(
        for route: VoiceEngineLanguageRoute,
        enablesHover: Bool = true
    ) -> some View {
        let model = route.model
        let isSelected = self.isOnboardingRouteSelected(route)
        let isHovered = enablesHover && self.hoveredModelRouteID == route.id
        let isRouteActiveInSettings = self.isRouteSelectedInSettings(route)
        let isDownloaded = self.isOnboardingModelBundledOrInstalled(model) || (isRouteActiveInSettings && (self.asr.isAsrReady || self.asr.modelsExistOnDisk))
        let isPreparing = self.preparingModelRouteID == route.id || (isRouteActiveInSettings && (self.asr.isDownloadingModel || (self.asr.isLoadingModel && !self.asr.isAsrReady)))
        let isReady = self.isOnboardingRouteReady(route)
        let isUninstalling = self.uninstallingModelRouteID == route.id
        let areModelActionsBlocked = self.asr.isRunning || self.uninstallingModelRouteID != nil || self.preparingModelRouteID != nil || isPreparing || self.isModelPreparationInProgress
        let isBuiltInAppleModel = model == .appleSpeech || model == .appleSpeechAnalyzer
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let cardFill = isHovered
            ? Color(red: 0.042, green: 0.052, blue: 0.074)
            : Color(red: 0.030, green: 0.038, blue: 0.056)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(self.onboardingModelTitle(for: model))
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Image(systemName: "info.circle")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .help(self.onboardingModelTooltip(for: route))
                    .accessibilityLabel(self.onboardingModelTooltip(for: route))
            }
            .frame(height: 38, alignment: .top)

            self.onboardingModelMetadataRow(badgeText: route.badgeText)

            self.onboardingModelFeaturePanel(for: model)

            Spacer(minLength: 0)

            Divider()
                .overlay(Color.white.opacity(0.10))

            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .frame(width: 22)

                Text("下载大小")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(Color.white.opacity(0.62))

                Spacer()

                Text(model.downloadSize)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
            }

            if isPreparing || isUninstalling {
                HStack(spacing: 8) {
                    self.onboardingModelPreparationStatus(isUninstalling: isUninstalling)

                    if isPreparing {
                        self.onboardingModelActionButton(
                            id: "\(route.id)-cancel",
                            title: self.asr.isCancellingModelPreparation ? "取消中…" : "取消",
                            systemImage: "xmark",
                            tone: .secondary,
                            width: 104,
                            isDisabled: self.asr.isCancellingModelPreparation
                        ) {
                            self.cancelOnboardingModelPreparation()
                        }
                    }
                }
                .frame(height: 42, alignment: .center)
            } else if isDownloaded, isBuiltInAppleModel {
                self.onboardingModelActionButton(
                    id: "\(route.id)-activate",
                    title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: true, isReady: isReady),
                    systemImage: isReady ? "checkmark" : "bolt.fill",
                    tone: .primary,
                    width: nil,
                    isDisabled: areModelActionsBlocked || isReady
                ) {
                    self.prepareOnboardingRoute(route)
                }
            } else if isDownloaded {
                HStack(spacing: 8) {
                    self.onboardingModelActionButton(
                        id: "\(route.id)-activate",
                        title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: true, isReady: isReady),
                        systemImage: isReady ? "checkmark" : "bolt.fill",
                        tone: .primary,
                        width: 124,
                        isDisabled: areModelActionsBlocked || isReady
                    ) {
                        self.prepareOnboardingRoute(route)
                    }

                    self.onboardingModelActionButton(
                        id: "\(route.id)-uninstall",
                        title: "删除",
                        systemImage: "trash",
                        tone: .destructive,
                        width: 124,
                        isDisabled: areModelActionsBlocked
                    ) {
                        self.uninstallOnboardingRoute(route)
                    }
                }
            } else {
                self.onboardingModelActionButton(
                    id: "\(route.id)-download-activate",
                    title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: false, isReady: false),
                    systemImage: "arrow.down.circle.fill",
                    tone: .primary,
                    width: nil,
                    isDisabled: areModelActionsBlocked
                ) {
                    self.prepareOnboardingRoute(route)
                }
            }
        }
        .padding(16)
        .frame(width: 292, height: 292, alignment: .topLeading)
        .background(
            shape
                .fill(cardFill)
                .overlay(
                    shape.stroke(
                        isSelected
                            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.92 : 0.78)
                            : (isHovered ? Color.white.opacity(0.20) : Color.white.opacity(0.10)),
                        lineWidth: isSelected ? 1.4 : 1
                    )
                )
        )
        .shadow(color: Color.black.opacity(0.34), radius: isHovered ? 20 : 14, x: 0, y: isHovered ? 12 : 8)
        .contentShape(shape)
        .onTapGesture {
            guard !areModelActionsBlocked else { return }
            self.selectOnboardingRoute(route)
        }
        .onHover { isHovered in
            guard enablesHover else { return }
            self.setHoveredModelRoute(isHovered ? route.id : nil)
        }
    }

    private func onboardingModelFeaturePanel(for model: SettingsStore.SpeechModel) -> some View {
        VStack(spacing: 10) {
            self.onboardingModelMetricRow(
                fillPercent: model.speedPercent,
                color: .yellow,
                secondaryColor: .orange,
                icon: "bolt.fill",
                label: "速度"
            )

            self.onboardingModelMetricRow(
                fillPercent: model.accuracyPercent,
                color: Color.fluidGreen,
                secondaryColor: .cyan,
                icon: "target",
                label: "准确率"
            )
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Speed \(Int(model.speedPercent * 100)) percent. Accuracy \(Int(model.accuracyPercent * 100)) percent.")
    }

    private func onboardingModelPreparationStatus(isUninstalling: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if self.asr.isCancellingModelPreparation {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()

                    Text("取消中...")
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            } else if self.asr.isDownloadingModel, let progress = self.asr.downloadProgress {
                ProgressView(value: progress)
                    .tint(FluidOnboardingLandingColors.blue)

                HStack(spacing: 6) {
                    Text("下载中 \(Int(progress * 100))%")
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()

                    Text(
                        isUninstalling
                            ? "删除中..."
                            : "加载模型中..."
                    )
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onboardingModelMetadataRow(badgeText: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let badgeText {
                Label(badgeText, systemImage: "checkmark.seal.fill")
                    .font(self.theme.typography.badge)
                    .foregroundStyle(Color.green.opacity(0.92))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(height: badgeText == nil ? 0 : 18, alignment: .leading)
    }

    private func onboardingModelMetricRow(
        fillPercent: Double,
        color: Color,
        secondaryColor: Color,
        icon: String,
        label: String
    ) -> some View {
        let clampedFill = min(max(fillPercent, 0), 1)

        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(color)

                Text(label)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(width: 86, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.075))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color, secondaryColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, proxy.size.width * CGFloat(clampedFill)))
                        .overlay(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.24),
                                            Color.clear,
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                }
            }
            .frame(height: 9)

            Text("\(Int(fillPercent * 100))%")
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(fillPercent > 0 ? color : Color.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .contentTransition(.numericText())
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 18)
    }

    private func onboardingModelActionButton(
        id: String,
        title: String,
        systemImage: String,
        tone: OnboardingPillButtonTone = .primary,
        width: CGFloat?,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = self.hoveredModelActionButtonID == id && !isDisabled

        return self.onboardingPillButton(
            configuration: OnboardingPillButtonConfiguration(
                title: title,
                systemImage: systemImage,
                tone: tone,
                width: width,
                height: 36,
                fontSize: 12,
                iconSize: 14,
                isHovered: isHovered,
                isEnabled: !isDisabled
            ),
            action: action
        ) { isHovered in
            self.setHoveredModelActionButton(isHovered ? id : nil)
        }
    }

    private func onboardingPillButton(
        configuration: OnboardingPillButtonConfiguration,
        action: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void
    ) -> some View {
        let shape = Capsule()
        let accentColor: Color = configuration.tone == .destructive ? .red : FluidOnboardingLandingColors.blue
        let isFilledTone = configuration.tone == .primary || configuration.tone == .destructive
        let fillColor: Color = {
            switch configuration.tone {
            case .primary, .destructive:
                return accentColor.opacity(configuration.isEnabled ? 1 : 0.34)
            case .secondary:
                return Color.white.opacity(configuration.isEnabled ? (configuration.isHovered ? 0.11 : 0.07) : 0.045)
            }
        }()
        let borderColor: Color = {
            switch configuration.tone {
            case .primary, .destructive:
                return Color.white.opacity(configuration.isHovered && configuration.isEnabled ? 0.30 : 0)
            case .secondary:
                return configuration.isHovered && configuration.isEnabled ? FluidOnboardingLandingColors.blue.opacity(0.30) : Color.white.opacity(0.07)
            }
        }()
        let foregroundOpacity: Double = configuration.isEnabled ? (isFilledTone ? 1.0 : (configuration.isHovered ? 0.94 : 0.78)) : 0.42
        let shadowOpacity: Double = {
            guard configuration.isEnabled else { return 0 }
            switch configuration.tone {
            case .primary, .destructive:
                return configuration.isHovered ? 0.56 : 0.26
            case .secondary:
                return configuration.isHovered ? 0.08 : 0
            }
        }()
        let ringOpacity: Double = configuration.isHovered && configuration.isEnabled ? 0.50 : 0

        return Button {
            action()
        } label: {
            HStack(spacing: configuration.systemImage == nil ? 0 : 8) {
                if let systemImage = configuration.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: configuration.iconSize, weight: .bold))
                }

                Text(configuration.title)
                    .font(.system(size: configuration.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.white.opacity(foregroundOpacity))
            .frame(width: configuration.width, height: configuration.height)
            .frame(maxWidth: configuration.width == nil ? .infinity : nil)
            .background(
                shape
                    .fill(fillColor)
                    .overlay(shape.fill(Color.white.opacity(isFilledTone && configuration.isHovered && configuration.isEnabled ? 0.10 : 0)))
                    .overlay(shape.stroke(borderColor, lineWidth: configuration.isHovered && configuration.isEnabled ? 1.2 : 1))
                    .overlay(
                        shape
                            .stroke(accentColor.opacity(ringOpacity), lineWidth: configuration.isHovered && configuration.isEnabled ? 1.4 : 1)
                            .padding(-2)
                    )
                    .shadow(color: accentColor.opacity(shadowOpacity), radius: configuration.isHovered && configuration.isEnabled ? 16 : 9, x: 0, y: configuration.isHovered && configuration.isEnabled ? 6 : 3)
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(shape)
        .disabled(!configuration.isEnabled)
        .onHover { isHovered in
            onHover(isHovered && configuration.isEnabled)
        }
    }

    private func onboardingModelTooltip(for route: VoiceEngineLanguageRoute) -> String {
        let model = route.model
        return "\(self.onboardingModelSubtitle(for: model)) - \(model.downloadSize)\n\(model.cardDescription)"
    }

    private func onboardingModelTitle(for model: SettingsStore.SpeechModel) -> String {
        model.humanReadableName
    }

    private func onboardingModelSubtitle(for model: SettingsStore.SpeechModel) -> String {
        switch model {
        case .parakeetTDT:
            return "Parakeet v3"
        case .parakeetTDTv2:
            return "Parakeet v2"
        case .parakeetRealtime:
            return "Parakeet Flash"
        case .cohereTranscribeSixBit:
            return "Cohere"
        case .nemotronStreaming:
            return "Nemotron Streaming"
        case .nemotronOffline:
            return "Nemotron Offline"
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return "Whisper"
        default:
            return model.displayName
        }
    }

    private func permissionRow(
        stepNumber: Int,
        title: String,
        subtitle: String,
        systemImage: String,
        isReady: Bool,
        statusTitle: String? = nil,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let resolvedStatusTitle = statusTitle ?? (isReady ? "已就绪" : "需要设置")

        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isReady ? Color.green.opacity(0.16) : FluidOnboardingLandingColors.blue.opacity(0.12))
                    .frame(width: 46, height: 46)

                if isReady {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.green.opacity(0.92))
                } else {
                    VStack(spacing: 1) {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .bold))

                        Text("\(stepNumber)")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(FluidOnboardingLandingColors.blue)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(resolvedStatusTitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isReady ? Color.green.opacity(0.92) : FluidOnboardingLandingColors.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((isReady ? Color.green : FluidOnboardingLandingColors.blue).opacity(0.12))
                        )
                }

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(2)
            }

            Spacer()

            if !isReady {
                let actionIcon = ["打开设置", "显示引导"].contains(actionTitle) ? "arrow.up.right" : "hand.tap.fill"
                let buttonID = "permission-\(stepNumber)"

                self.onboardingPillButton(
                    configuration: OnboardingPillButtonConfiguration(
                        title: actionTitle,
                        systemImage: actionIcon,
                        tone: .primary,
                        width: 132,
                        height: 36,
                        fontSize: 12,
                        iconSize: 10,
                        isHovered: self.hoveredPermissionButtonID == buttonID,
                        isEnabled: true
                    ),
                    action: action
                ) { isHovered in
                    self.setHoveredPermissionButton(isHovered ? buttonID : nil)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 88)
        .background(
            shape
                .fill(Color.white.opacity(isReady ? 0.045 : 0.070))
                .overlay(
                    shape.stroke(
                        isReady ? Color.green.opacity(0.18) : FluidOnboardingLandingColors.blue.opacity(0.26),
                        lineWidth: 1
                    )
                )
        )
    }

    private func isOnboardingRouteSelected(_ route: VoiceEngineLanguageRoute) -> Bool {
        self.selectedOnboardingRoute?.id == route.id || self.isRouteSelectedInSettings(route)
    }

    private func isRouteSelectedInSettings(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return self.settings.onboardingSelectedLanguageID == route.language.id
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    private func isRouteModelAndLanguageSettingsSelected(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return true
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    private func selectOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        let oldModel = self.settings.selectedSpeechModel
        let oldAppleSpeechLocaleIdentifier = self.settings.selectedAppleSpeechLocaleIdentifier
        let oldCohereLanguage = self.settings.selectedCohereLanguage
        let oldNemotronLanguage = self.settings.selectedNemotronLanguage

        self.selectedModelRouteID = route.id
        VoiceEngineLanguageCatalog.apply(route, to: self.settings)

        let languageChanged: Bool
        switch route.binding {
        case .automatic, .whisper:
            languageChanged = false
        case .appleSpeech:
            languageChanged = oldAppleSpeechLocaleIdentifier != self.settings.selectedAppleSpeechLocaleIdentifier
        case .cohere:
            languageChanged = oldCohereLanguage != self.settings.selectedCohereLanguage
        case .nemotron:
            languageChanged = oldNemotronLanguage != self.settings.selectedNemotronLanguage
        }

        if oldModel != self.settings.selectedSpeechModel || languageChanged {
            self.resetTryoutValidationForSetupChange()
            self.asr.resetTranscriptionProvider()
        }
    }

    private func setHoveredModelRoute(_ routeID: String?) {
        guard self.hoveredModelRouteID != routeID else { return }
        if self.reduceMotion {
            self.hoveredModelRouteID = routeID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredModelRouteID = routeID
            }
        }
    }

    private func setHoveredModelActionButton(_ buttonID: String?) {
        guard self.hoveredModelActionButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredModelActionButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredModelActionButtonID = buttonID
            }
        }
    }

    private func setHoveredPermissionButton(_ buttonID: String?) {
        guard self.hoveredPermissionButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredPermissionButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredPermissionButtonID = buttonID
            }
        }
    }

    private func togglePrimaryShortcutRecording() {
        guard !self.asr.isRunning else { return }
        if self.isRecordingPrimaryShortcut {
            self.activeShortcutRecordingTarget = nil
            self.shortcutRecordingMessage = nil
        } else {
            self.shortcutRecordingMessage = nil
            self.activeShortcutRecordingTarget = .primaryDictation(.replace(0))
        }
    }

    private func resetTryoutValidationForSetupChange() {
        self.settings.onboardingPlaygroundValidated = false
        self.settings.onboardingPlaygroundSkipped = false
        self.settings.playgroundUsed = false
        self.asr.finalText = ""
    }

    private func handleMicrophoneAction() {
        if self.asr.micStatus == .notDetermined {
            self.asr.requestMicAccess()
        } else {
            self.asr.openSystemSettingsForMic()
        }
    }

    private func goBack() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = max(0, self.currentStep - 1)
    }

    private func goNext() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = min(Step.allCases.count - 1, self.currentStep + 1)
    }

    private func handlePrimaryAction() {
        guard !self.isModelPreparationInProgress else {
            return
        }

        if self.step == .language, let route = self.selectedOnboardingRoute {
            self.selectOnboardingRoute(route)
        }

        if self.step == .aiEnhancement {
            guard self.isAIReady else { return }
            self.finishOnboarding()
            return
        }
        self.goNext()
    }
}
