//
//  SettingsView.swift
//  fluid
//
//  App preferences and audio device settings
//

import AppKit
import AVFoundation
import PromiseKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private struct ShortcutRowContent {
        let icon: String
        let iconColor: Color
        let title: String
        let description: String
    }

    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @Binding var appear: Bool
    @Binding var visualizerNoiseThreshold: Double
    @Binding var selectedInputUID: String
    @Binding var selectedOutputUID: String
    @Binding var inputDevices: [AudioDevice.Device]
    @Binding var outputDevices: [AudioDevice.Device]
    @Binding var accessibilityEnabled: Bool
    @Binding var primaryDictationShortcuts: [HotkeyShortcut]
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    @Binding var commandModeShortcut: HotkeyShortcut?
    @Binding var rewriteShortcut: HotkeyShortcut
    @Binding var cancelRecordingShortcut: HotkeyShortcut
    @Binding var pasteLastTranscriptionShortcut: HotkeyShortcut?
    @Binding var commandModeShortcutEnabled: Bool
    @Binding var rewriteShortcutEnabled: Bool
    @Binding var pasteLastTranscriptionShortcutEnabled: Bool
    @Binding var hotkeyManagerInitialized: Bool
    @Binding var hotkeyMode: HotkeyActivationMode
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool

    // CRITICAL FIX: Cache default device names to avoid CoreAudio calls during view body evaluation.
    // Querying AudioDevice.getDefaultInputDevice() in the view body triggers HALSystem::InitializeShell()
    // which races with SwiftUI's AttributeGraph metadata processing and causes EXC_BAD_ACCESS crashes.
    @State private var cachedDefaultInputName: String = ""
    @State private var cachedDefaultOutputName: String = ""

    // Analytics consent UI state (default ON; user can opt-out)
    @State private var shareAnonymousAnalytics: Bool = SettingsStore.shared.shareAnonymousAnalytics
    @State private var showAnalyticsPrivacy: Bool = false
    @State private var pendingAnalyticsValue: Bool? = nil
    @State private var showAreYouSureToStopAnalytics: Bool = false
    @State private var rollbackVersion: String = ""
    @State private var isRollingBack: Bool = false
    @State private var audioHistoryBudgetText: String = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    @State private var audioHistoryUsageBytes: Int64 = DictationAudioHistoryStore.shared.audioUsageBytes()

    let hotkeyManager: GlobalHotkeyManager?
    let menuBarManager: MenuBarManager
    let startRecording: () -> Void
    let refreshDevices: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let revealAppInFinder: () -> Void
    let openApplicationsFolder: () -> Void

    private var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    private var settingsTitleText: Color {
        Color(nsColor: .labelColor)
    }

    private var settingsSecondaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82)
    }

    private var settingsTertiaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.85) : self.theme.palette.secondaryText
    }

    private func isRecording(_ target: ShortcutRecordingTarget) -> Bool {
        self.activeShortcutRecordingTarget == target
    }

    private var analyticsToggleBinding: Binding<Bool> {
        Binding(
            get: {
                self.pendingAnalyticsValue ?? self.shareAnonymousAnalytics
            },
            set: { newValue in
                // User is trying to turn OFF → ask first
                if self.shareAnonymousAnalytics == true, newValue == false {
                    self.pendingAnalyticsValue = false
                    self.showAreYouSureToStopAnalytics = true

                    return
                }

                // Normal ON path
                self.shareAnonymousAnalytics = newValue
                self.applyAnalyticsConsentChange(newValue)
            }
        )
    }

    private var analyticsConfirmationBinding: Binding<Bool> {
        Binding(
            get: { self.showAreYouSureToStopAnalytics },
            set: { newValue in
                // Only open modal if we have a pending value
                if newValue {
                    if self.pendingAnalyticsValue != nil {
                        self.showAreYouSureToStopAnalytics = true
                    }
                } else {
                    // Closing the modal: reset pending state
                    self.showAreYouSureToStopAnalytics = false
                    self.pendingAnalyticsValue = nil
                }
            }
        )
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var appDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    private var launchAtStartupBinding: Binding<Bool> {
        Binding(
            get: { self.settings.launchAtStartupEnabled },
            set: { self.settings.setLaunchAtStartup($0) }
        )
    }

    private func dictationPromptSelectionBinding(for slot: SettingsStore.DictationShortcutSlot) -> Binding<String> {
        Binding(
            get: {
                switch self.settings.dictationPromptSelection(for: slot) {
                case .off:
                    return "__OFF__"
                case .default:
                    return "__DEFAULT__"
                case .privateAI:
                    return PrivateAIProviderPromptFormat.promptSelectionID
                case let .profile(id):
                    return id
                }
            },
            set: { newValue in
                switch newValue {
                case "__OFF__":
                    self.settings.setDictationPromptSelection(.off, for: slot)
                case "__DEFAULT__":
                    guard !PrivateAIProviderPromptFormat.isAvailable(settings: self.settings) else { return }
                    self.settings.setDictationPromptSelection(.default, for: slot)
                case PrivateAIProviderPromptFormat.promptSelectionID:
                    guard PrivateAIProviderPromptFormat.isAvailable(settings: self.settings) else { return }
                    self.settings.setDictationPromptSelection(.privateAI, for: slot)
                default:
                    guard !PrivateAIProviderPromptFormat.isAvailable(settings: self.settings) else { return }
                    self.settings.setDictationPromptSelection(.profile(newValue), for: slot)
                }
            }
        )
    }

    @ViewBuilder
    private func dictationPromptPicker(for slot: SettingsStore.DictationShortcutSlot) -> some View {
        let profiles = self.settings.promptProfiles(for: .dictate)
        let privateAILocked = PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
        HStack {
            Text("AI 提示词")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.settingsSecondaryText)
                .padding(.leading, 30)
            Spacer()
            Picker("", selection: self.dictationPromptSelectionBinding(for: slot)) {
                Text("关闭").tag("__OFF__")
                Text("默认").tag("__DEFAULT__").disabled(privateAILocked)
                if PrivateFeatures.privateAIProvider {
                    Text(PrivateAIProviderFeature.displayName)
                        .tag(PrivateAIProviderPromptFormat.promptSelectionID)
                        .disabled(!privateAILocked)
                }
                ForEach(profiles) { profile in
                    Text(profile.name.isEmpty ? "未命名" : profile.name)
                        .tag(profile.id)
                        .disabled(privateAILocked)
                }
            }
            .frame(width: 190)
        }
        .padding(.bottom, 4)
    }

    var body: some View {
        SettingsPersistentScrollView(theme: self.theme, colorScheme: self.colorScheme) {
            VStack(spacing: 16) {
                // App Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Section header
                        Label("应用设置", systemImage: "power")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(spacing: 16) {
                            // Launch at startup
                            self.settingsToggleRow(
                                title: "开机自动启动",
                                description: "登录时自动启动 FluidVoice",
                                footnote: self.settings.launchAtStartupStatusMessage,
                                errorMessage: self.settings.launchAtStartupErrorMessage,
                                isOn: self.launchAtStartupBinding
                            )
                            Divider().opacity(0.2)

                            // Show window when launched at login
                            self.settingsToggleRow(
                                title: "登录启动时显示窗口",
                                description: "关闭后，FluidVoice 在登录时静默运行于菜单栏。手动打开应用时始终显示窗口。",
                                isOn: Binding(
                                    get: { SettingsStore.shared.showMainWindowAtLoginLaunch },
                                    set: { SettingsStore.shared.showMainWindowAtLoginLaunch = $0 }
                                )
                            )
                            Divider().opacity(0.2)

                            // Hide from Dock & App Switcher
                            self.settingsToggleRow(
                                title: "从程序坞和应用切换器隐藏",
                                description: "仅在菜单栏中保留 FluidVoice（隐藏程序坞图标和 Cmd+Tab 条目）",
                                footnote: "注意：可能需要重启应用才能生效。",
                                isOn: Binding(
                                    get: { SettingsStore.shared.hideFromDockAndAppSwitcher },
                                    set: { SettingsStore.shared.hideFromDockAndAppSwitcher = $0 }
                                )
                            )
                            Divider().opacity(0.2)

                            // Accent Color
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("强调色")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("为应用选择一个预设强调色。")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    HStack(spacing: 10) {
                                        ForEach(SettingsStore.AccentColorOption.allCases) { option in
                                            let isSelected = self.settings.accentColorOption == option
                                            Button {
                                                self.settings.accentColorOption = option
                                            } label: {
                                                Circle()
                                                    .fill(Color(hex: option.hex) ?? .gray)
                                                    .frame(width: 16, height: 16)
                                                    .overlay(
                                                        Circle()
                                                            .stroke(
                                                                isSelected ? self.theme.palette.accent : self.theme.palette.cardBorder.opacity(0.5),
                                                                lineWidth: isSelected ? 2 : 1
                                                            )
                                                    )
                                                    .padding(4)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(option.rawValue)
                                            .help(option.rawValue)
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(self.theme.palette.contentBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(self.theme.palette.cardBorder.opacity(0.4), lineWidth: 1)
                                            )
                                    )
                                }
                            }
                            Divider().opacity(0.2)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("转录提示音")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("选择录音提示音。部分提示音包含结束提示。")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Picker("", selection: Binding(
                                    get: { SettingsStore.shared.transcriptionStartSound },
                                    set: { newValue in
                                        SettingsStore.shared.transcriptionStartSound = newValue
                                        TranscriptionSoundPlayer.shared.playPreview(sound: newValue)
                                    }
                                )) {
                                    ForEach(SettingsStore.TranscriptionStartSound.allCases) { option in
                                        Text(option.displayName).tag(option)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170, alignment: .trailing)
                            }

                            if SettingsStore.shared.transcriptionStartSound != .none {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("音量")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("调整录音提示音的音量。")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Slider(
                                        value: Binding(
                                            get: { Double(SettingsStore.shared.transcriptionSoundVolume) },
                                            set: { SettingsStore.shared.transcriptionSoundVolume = Float($0) }
                                        ),
                                        in: 0...1,
                                        step: 0.05
                                    ) { editing in
                                        if !editing {
                                            TranscriptionSoundPlayer.shared.playPreviewAtVolume(
                                                SettingsStore.shared.transcriptionSoundVolume
                                            )
                                        }
                                    }
                                    .frame(width: 150)
                                }

                                self.settingsToggleRow(
                                    title: "独立音量",
                                    description: "无论系统音量如何，提示音音量保持不变。静音仍然有效。",
                                    footnote: "播放期间会临时调整系统音量，可能短暂影响其他音频。",
                                    isOn: Binding(
                                        get: { SettingsStore.shared.transcriptionSoundIndependentVolume },
                                        set: { SettingsStore.shared.transcriptionSoundIndependentVolume = $0 }
                                    )
                                )
                            }

                            Divider().opacity(0.2)

                            // Automatic Updates
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("自动更新")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("每小时自动检查一次更新")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Binding(
                                        get: { SettingsStore.shared.autoUpdateCheckEnabled },
                                        set: { SettingsStore.shared.autoUpdateCheckEnabled = $0 }
                                    ))
                                    .toggleStyle(.switch)
                                    .tint(self.theme.palette.accent)
                                    .labelsHidden()
                                }

                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("测试版")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("加入可能不稳定的预览版本")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Binding(
                                        get: { SettingsStore.shared.betaReleasesEnabled },
                                        set: { SettingsStore.shared.betaReleasesEnabled = $0 }
                                    ))
                                    .toggleStyle(.switch)
                                    .tint(self.theme.palette.accent)
                                    .labelsHidden()
                                }

                                if SettingsStore.shared.betaReleasesEnabled {
                                    Text("已加入测试版。更新检查将包含正式版和测试版。")
                                        .font(.caption)
                                        .foregroundStyle(self.theme.palette.warning)
                                }

                                if let lastCheck = SettingsStore.shared.lastUpdateCheckDate {
                                    Text("上次检查：\(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Text("当前版本：\(self.currentAppVersion)")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)
                            }

                            // Update Buttons
                            HStack(spacing: 10) {
                                Button("检查更新") {
                                    Task { @MainActor in
                                        do {
                                            let includePrerelease = SettingsStore.shared.betaReleasesEnabled
                                            try await SimpleUpdater.shared.checkAndUpdate(
                                                owner: "altic-dev",
                                                repo: "Fluid-oss",
                                                includePrerelease: includePrerelease
                                            )
                                            let ok = NSAlert()
                                            ok.messageText = "发现更新！"
                                            ok.informativeText = "有新版本可用，即将开始安装。"
                                            ok.alertStyle = .informational
                                            ok.addButton(withTitle: "好")
                                            ok.runModal()
                                        } catch {
                                            let msg = NSAlert()
                                            if let pmkError = error as? PMKError, pmkError.isCancelled {
                                                let isBeta = SettingsStore.shared.betaReleasesEnabled
                                                msg.messageText = isBeta ? "已是最新版本（测试版）" : "已是最新版本"
                                                msg.informativeText = isBeta
                                                    ? "您已在运行测试渠道中最新的版本。"
                                                    : "您已在运行最新版本的 FluidVoice。"
                                            } else {
                                                msg.messageText = "检查更新失败"
                                                msg.informativeText = "无法检查更新，请稍后再试。\n\n错误：\(error.localizedDescription)"
                                            }
                                            msg.alertStyle = .informational
                                            msg.runModal()
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(self.theme.palette.accent)
                                .controlSize(.regular)

                                Button("更新日志") {
                                    if let url = URL(string: "https://github.com/altic-dev/Fluid-oss/releases") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)

                                Button(self.rollbackVersion.isEmpty ? "回滚" : "回滚至 \(self.rollbackVersion)") {
                                    guard !self.isRollingBack else { return }

                                    let infoText = self.rollbackVersion.isEmpty ? "上一个已安装版本" : self.rollbackVersion
                                    let targetVersion = self.rollbackVersion
                                    let confirm = NSAlert()
                                    confirm.messageText = "回滚至 \(infoText)？"
                                    confirm.informativeText = "这将还原到之前的应用版本并重新启动 FluidVoice。"
                                    confirm.alertStyle = .warning
                                    confirm.addButton(withTitle: "回滚")
                                    confirm.addButton(withTitle: "取消")

                                    guard confirm.runModal() == .alertFirstButtonReturn else { return }

                                    self.isRollingBack = true
                                    Task {
                                        defer {
                                            Task { @MainActor in
                                                self.isRollingBack = false
                                            }
                                        }

                                        do {
                                            try await SimpleUpdater.shared.rollbackToLatestBackup()
                                            await MainActor.run {
                                                let success = NSAlert()
                                                success.messageText = "回滚成功"
                                                success.informativeText = "已回滚至 \(targetVersion)。FluidVoice 将在片刻后重新启动。"
                                                success.alertStyle = .informational
                                                success.addButton(withTitle: "报告问题")
                                                success.addButton(withTitle: "好")
                                                let response = success.runModal()
                                                if response == .alertFirstButtonReturn {
                                                    self.openIssueReportingPage()
                                                }
                                            }
                                        } catch {
                                            await MainActor.run {
                                                let fail = NSAlert()
                                                fail.messageText = "回滚失败"
                                                fail.informativeText = error.localizedDescription
                                                fail.alertStyle = .critical
                                                fail.addButton(withTitle: "好")
                                                fail.runModal()
                                                self.refreshRollbackState()
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(self.rollbackVersion.isEmpty || self.isRollingBack)
                                .opacity(self.isRollingBack ? 0.7 : 1.0)

                                Button("获取历史版本") {
                                    self.openPreviousBuildPicker()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                            }
                            .padding(.top, 12)

                            if self.rollbackVersion.isEmpty {
                                Text("未找到回滚备份。")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)
                            } else {
                                Text("回滚目标：\(self.rollbackVersion)")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)
                            }
                        }
                    }
                    .padding(16)
                }

                // Microphone Permission Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("麦克风权限", systemImage: "mic.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(self.asr.micStatus == .authorized ? self.theme.palette.success : self.theme.palette.warning)
                                    .frame(width: 8, height: 8)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        self.asr.micStatus == .authorized ? "已授予麦克风访问权限" :
                                            self.asr.micStatus == .denied ? "已拒绝麦克风访问权限" :
                                            "麦克风访问权限尚未确定"
                                    )
                                    .font(self.theme.typography.bodyStrong)
                                    .foregroundStyle(self.asr.micStatus == .authorized ? .primary : self.theme.palette.warning)

                                    if self.asr.micStatus != .authorized {
                                        Text("语音录制需要麦克风访问权限")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                }
                                Spacer()

                                if self.asr.micStatus == .notDetermined {
                                    Button {
                                        self.asr.requestMicAccess()
                                    } label: {
                                        Label("授予权限", systemImage: "mic.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(self.theme.palette.accent)
                                    .controlSize(.regular)
                                } else if self.asr.micStatus == .denied {
                                    Button {
                                        self.asr.openSystemSettingsForMic()
                                    } label: {
                                        Label("打开设置", systemImage: "gear")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                }
                            }

                            if self.asr.micStatus != .authorized {
                                self.instructionsBox(
                                    title: "如何启用麦克风访问权限：",
                                    steps: self.asr.micStatus == .notDetermined
                                        ? ["点击上方的**授予权限**", "在系统弹窗中选择**允许**"]
                                        : [
                                            "点击上方的**打开设置**",
                                            "在麦克风列表中找到 **\(self.appDisplayName)**",
                                            "将 **\(self.appDisplayName)** 的开关**打开**以允许访问",
                                        ]
                                )
                            }
                        }
                    }
                    .padding(16)
                }

                // Global Hotkey Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Label("全局快捷键", systemImage: "keyboard")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Spacer()

                            if self.accessibilityEnabled {
                                if self.isRecordingAnyShortcut {
                                    Text("录制中…")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                } else if self.hotkeyManagerInitialized {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.fluidGreen)
                                            .font(.caption)
                                        Text("已激活")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                } else {
                                    Text("初始化中…")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(self.settingsSecondaryText)
                                }
                            }
                        }

                        if self.accessibilityEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                if self.isRecordingAnyShortcut {
                                    HStack(spacing: 8) {
                                        Image(systemName: "hand.point.up.left.fill")
                                            .foregroundStyle(.orange)
                                        Text("请立即按下新的快捷键组合…")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                } else if !self.hotkeyManagerInitialized {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .fixedSize()
                                        Text("快捷键初始化中…")
                                            .font(.caption)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                }

                                // MARK: - Shortcuts Section

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("快捷键")
                                        .font(self.theme.typography.bodySmallStrong)
                                        .foregroundStyle(self.settingsTitleText)

                                    Text("主听写可使用键盘快捷键或允许的鼠标按键，更改通常立即生效。")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsTertiaryText)

                                    self.primaryDictationShortcutsList()
                                    self.dictationPromptPicker(for: .primary)
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "terminal.fill",
                                            iconColor: .secondary,
                                            title: "命令模式",
                                            description: "执行语音命令"
                                        ),
                                        shortcut: self.commandModeShortcut,
                                        isRecording: self.isRecording(.command),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.command) ? self.shortcutRecordingMessage : nil,
                                        isEnabled: self.$commandModeShortcutEnabled,
                                        requiresShortcutToEnable: true,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new command mode shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .command
                                        },
                                        onRemovePressed: {
                                            if self.activeShortcutRecordingTarget == .command {
                                                self.shortcutRecordingMessage = nil
                                                self.activeShortcutRecordingTarget = nil
                                            }
                                            self.commandModeShortcut = nil
                                            self.commandModeShortcutEnabled = false
                                        }
                                    )
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "pencil.and.outline",
                                            iconColor: .secondary,
                                            title: "编辑模式",
                                            description: "选中文本后说出编辑指令，或生成新内容"
                                        ),
                                        shortcut: self.rewriteShortcut,
                                        isRecording: self.isRecording(.edit),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.edit) ? self.shortcutRecordingMessage : nil,
                                        isEnabled: self.$rewriteShortcutEnabled,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new write mode shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .edit
                                        }
                                    )
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "xmark.circle.fill",
                                            iconColor: .secondary,
                                            title: "取消录音",
                                            description: "取消当前录音或关闭活跃的录音悬浮窗"
                                        ),
                                        shortcut: self.cancelRecordingShortcut,
                                        isRecording: self.isRecording(.cancel),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.cancel) ? self.shortcutRecordingMessage : nil,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new cancel shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .cancel
                                        }
                                    )
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "arrow.down.doc",
                                            iconColor: .secondary,
                                            title: "粘贴上次转录",
                                            description: "重新插入最近的转录内容，无需使用剪贴板"
                                        ),
                                        shortcut: self.pasteLastTranscriptionShortcut,
                                        isRecording: self.isRecording(.pasteLast),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.pasteLast) ? self.shortcutRecordingMessage : nil,
                                        isEnabled: self.$pasteLastTranscriptionShortcutEnabled,
                                        requiresShortcutToEnable: true,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new paste last transcription shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .pasteLast
                                        },
                                        onRemovePressed: {
                                            if self.activeShortcutRecordingTarget == .pasteLast {
                                                self.shortcutRecordingMessage = nil
                                                self.activeShortcutRecordingTarget = nil
                                            }
                                            self.pasteLastTranscriptionShortcut = nil
                                            self.pasteLastTranscriptionShortcutEnabled = false
                                        }
                                    )
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(self.theme.palette.elevatedCardBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                                        )
                                )

                                // MARK: - Options Section

                                VStack(spacing: 12) {
                                    HStack(alignment: .center) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("激活模式")
                                                .font(self.theme.typography.bodyStrong)
                                                .foregroundStyle(self.settingsTitleText)
                                            Text(self.hotkeyMode.description)
                                                .font(self.theme.typography.bodySmall)
                                                .foregroundStyle(self.settingsSecondaryText)
                                        }

                                        Spacer()

                                        Picker("", selection: self.$hotkeyMode) {
                                            ForEach(HotkeyActivationMode.allCases) { mode in
                                                Text(mode.displayName).tag(mode)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(width: 170, alignment: .trailing)
                                    }
                                    .onChange(of: self.hotkeyMode) { _, newValue in
                                        SettingsStore.shared.hotkeyMode = newValue
                                        self.hotkeyManager?.setHotkeyMode(newValue)
                                    }
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "复制到剪贴板",
                                        description: "自动将转录文本复制到剪贴板作为备份。",
                                        isOn: self.$copyToClipboard
                                    )
                                    .onChange(of: self.copyToClipboard) { _, newValue in
                                        SettingsStore.shared.copyTranscriptionToClipboard = newValue
                                    }
                                    Divider().opacity(0.2)

                                    HStack(alignment: .center) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("文本插入模式")
                                                .font(self.theme.typography.bodyStrong)
                                                .foregroundStyle(self.settingsTitleText)
                                            Text(SettingsStore.shared.textInsertionMode.description)
                                                .font(self.theme.typography.bodySmall)
                                                .foregroundStyle(self.settingsSecondaryText)
                                        }

                                        Spacer()

                                        Picker("", selection: Binding(
                                            get: { SettingsStore.shared.textInsertionMode },
                                            set: { SettingsStore.shared.textInsertionMode = $0 }
                                        )) {
                                            ForEach(SettingsStore.TextInsertionMode.allCases) { mode in
                                                Text(mode.displayName).tag(mode)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(width: 170, alignment: .trailing)
                                    }
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "保存转录历史",
                                        description: "保存转录内容以用于统计追踪。如需保护隐私，可关闭此选项。",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.saveTranscriptionHistory },
                                            set: {
                                                SettingsStore.shared.saveTranscriptionHistory = $0
                                                self.refreshAudioHistoryUsage()
                                            }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "随历史保存音频",
                                        description: "将实际麦克风音频与听写历史一同保存在本地。默认关闭。",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.saveAudioWithTranscriptionHistory },
                                            set: {
                                                SettingsStore.shared.saveAudioWithTranscriptionHistory = $0
                                                self.refreshAudioHistoryUsage()
                                            }
                                        )
                                    )
                                    .disabled(!SettingsStore.shared.saveTranscriptionHistory)

                                    if SettingsStore.shared.saveTranscriptionHistory,
                                       SettingsStore.shared.saveAudioWithTranscriptionHistory
                                    {
                                        self.audioHistoryControls()
                                            .padding(.top, 2)
                                        Divider().opacity(0.2)
                                    } else {
                                        Divider().opacity(0.2)
                                    }

                                    self.optionToggleRow(
                                        title: "通知 AI 增强失败",
                                        description: "当 AI 增强失败并输出原始转录内容时，显示 macOS 通知。",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.notifyAIProcessingFailures },
                                            set: { SettingsStore.shared.notifyAIProcessingFailures = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "周末不中断连续记录",
                                        description: "计算使用连续天数时跳过周六和周日，适合仅在工作日使用的用户。",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.weekendsDontBreakStreak },
                                            set: { SettingsStore.shared.weekendsDontBreakStreak = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "首字母小写",
                                        description: "每次转录以小写字母开头，适用于搜索词、表单字段或非正式文本。",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.gaavLowercaseFirstLetterEnabled },
                                            set: { SettingsStore.shared.gaavLowercaseFirstLetterEnabled = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "移除末尾句点",
                                        description: "去掉转录内容末尾的句点。",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.gaavRemoveTrailingPeriodEnabled },
                                            set: { SettingsStore.shared.gaavRemoveTrailingPeriodEnabled = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "听写间自动空格",
                                        description: "自动添加空格，使连续听写无需手动按空格键。",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.continuousDictationSpacingEnabled },
                                            set: { SettingsStore.shared.continuousDictationSpacingEnabled = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "智能大写",
                                        description: "根据光标前的文本，自动判断下次听写是否应首字母大写。",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.contextAwareCapitalizationEnabled },
                                            set: { SettingsStore.shared.contextAwareCapitalizationEnabled = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "转录时暂停媒体",
                                        description: "转录开始时自动暂停当前播放的音视频，仅当由 FluidVoice 暂停时才会恢复。",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.pauseMediaDuringTranscription },
                                            set: { SettingsStore.shared.pauseMediaDuringTranscription = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "分享匿名统计数据",
                                        description: "发送匿名使用情况和性能指标，帮助改进 FluidVoice。永远不包含转录文本或提示词。",
                                        isOn: self.analyticsToggleBinding
                                    )

                                    HStack {
                                        Button("我们收集的内容") {
                                            self.showAnalyticsPrivacy = true
                                        }
                                        .buttonStyle(.link)

                                        Spacer()
                                    }
                                    .padding(.top, 6)
                                }
                                .padding(12)
                            }
                        } else {
                            // Hotkey disabled - accessibility not enabled
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(self.theme.palette.warning)
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(self.theme.palette.warning)
                                            Text("需要辅助功能权限")
                                                .font(self.theme.typography.bodyStrong)
                                                .foregroundStyle(self.theme.palette.warning)
                                        }
                                        Text("全局快捷键功能需要此权限")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                    Spacer()

                                    Button("打开辅助功能设置") {
                                        self.openAccessibilitySettings()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(self.theme.palette.accent)
                                    .controlSize(.regular)
                                }

                                self.instructionsBox(
                                    title: "请按以下步骤启用辅助功能：",
                                    steps: [
                                        "点击上方的**打开辅助功能设置**",
                                        "在辅助功能窗口中，点击 **+ 按钮**",
                                        "选择 **\(self.appDisplayName)**；如需定位，请使用下方的**在 Finder 中显示**",
                                        "点击**打开**，然后在列表中将 **\(self.appDisplayName)** 的开关**打开**",
                                    ],
                                    warningStyle: true
                                )

                                HStack(spacing: 10) {
                                    Button("在 Finder 中显示") {
                                        self.revealAppInFinder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("打开应用程序文件夹") {
                                        self.openApplicationsFolder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(16)
                }

                // Audio Devices Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("音频设备", systemImage: "speaker.wave.2.fill")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Spacer()

                            Button {
                                self.refreshDevices()
                                // Update cached default device names on refresh
                                self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""
                                self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        // Info note about device syncing
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(self.settingsSecondaryText)
                                .font(self.theme.typography.bodyStrong)
                            Text("音频设备与 macOS 系统设置同步。")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("输入设备")
                                    .font(self.theme.typography.bodyStrong)
                                    .foregroundStyle(self.settingsTitleText)
                                Spacer()
                                Picker("", selection: self.$selectedInputUID) {
                                    // Handle empty state gracefully
                                    if self.inputDevices.isEmpty {
                                        Text("加载中…").tag("")
                                    } else {
                                        ForEach(self.inputDevices, id: \.uid) { dev in
                                            // Add "(System Default)" tag using cached name to avoid CoreAudio calls during layout
                                            let isSystemDefault = !self.cachedDefaultInputName.isEmpty && dev.name == self.cachedDefaultInputName
                                            Text(isSystemDefault ? "\(dev.name)（系统默认）" : dev.name).tag(dev.uid)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .disabled(self.asr.isRunning) // Disable device changes during recording
                                .onChange(of: self.selectedInputUID) { oldUID, newUID in
                                    guard !newUID.isEmpty else { return }

                                    // Prevent device changes during active recording
                                    if self.asr.isRunning {
                                        DebugLogger.shared.warning("Cannot change input device during recording", source: "SettingsView")
                                        // Revert to previous value
                                        self.selectedInputUID = oldUID
                                        return
                                    }

                                    SettingsStore.shared.preferredInputDeviceUID = newUID
                                    // Only change system default if sync is enabled
                                    if SettingsStore.shared.syncAudioDevicesWithSystem {
                                        _ = AudioDevice.setDefaultInputDevice(uid: newUID)
                                    }
                                }
                                // Sync selection when devices load or change
                                .onChange(of: self.inputDevices) { _, newDevices in
                                    // Update cached default device name when device list changes
                                    self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""

                                    // If selection is empty or not found in new list, select first available
                                    if !newDevices.isEmpty {
                                        let currentValid = newDevices.contains { $0.uid == self.selectedInputUID }
                                        if !currentValid {
                                            if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid,
                                               newDevices.contains(where: { $0.uid == defaultUID })
                                            {
                                                self.selectedInputUID = defaultUID
                                            } else {
                                                self.selectedInputUID = newDevices.first?.uid ?? ""
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                Text("输出设备")
                                    .font(self.theme.typography.bodyStrong)
                                    .foregroundStyle(self.settingsTitleText)
                                Spacer()
                                Picker("", selection: self.$selectedOutputUID) {
                                    // Handle empty state gracefully
                                    if self.outputDevices.isEmpty {
                                        Text("加载中…").tag("")
                                    } else {
                                        ForEach(self.outputDevices, id: \.uid) { dev in
                                            // Add "(System Default)" tag using cached name to avoid CoreAudio calls during layout
                                            let isSystemDefault = !self.cachedDefaultOutputName.isEmpty && dev.name == self.cachedDefaultOutputName
                                            Text(isSystemDefault ? "\(dev.name) (System Default)" : dev.name).tag(dev.uid)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .disabled(self.asr.isRunning) // Disable device changes during recording
                                .onChange(of: self.selectedOutputUID) { oldUID, newUID in
                                    guard !newUID.isEmpty else { return }

                                    // Prevent device changes during active recording
                                    if self.asr.isRunning {
                                        DebugLogger.shared.warning("Cannot change output device during recording", source: "SettingsView")
                                        // Revert to previous value
                                        self.selectedOutputUID = oldUID
                                        return
                                    }

                                    SettingsStore.shared.preferredOutputDeviceUID = newUID
                                    // Only change system default if sync is enabled
                                    if SettingsStore.shared.syncAudioDevicesWithSystem {
                                        _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
                                    }
                                }
                                // Sync selection when devices load or change
                                .onChange(of: self.outputDevices) { _, newDevices in
                                    // Update cached default device name when device list changes
                                    self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""

                                    if !newDevices.isEmpty {
                                        let currentValid = newDevices.contains { $0.uid == self.selectedOutputUID }
                                        if !currentValid {
                                            if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                                               newDevices.contains(where: { $0.uid == prefUID })
                                            {
                                                self.selectedOutputUID = prefUID
                                            } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                                                      newDevices.contains(where: { $0.uid == defaultUID })
                                            {
                                                self.selectedOutputUID = defaultUID
                                            } else {
                                                self.selectedOutputUID = newDevices.first?.uid ?? ""
                                            }
                                        }
                                    }
                                }
                            }

                            // CRITICAL FIX: Use cached values instead of querying CoreAudio in view body.
                            // Querying AudioDevice here triggers HALSystem::InitializeShell() race condition.
                            if !self.cachedDefaultInputName.isEmpty && !self.cachedDefaultOutputName.isEmpty {
                                HStack {
                                    Spacer()
                                    Text("默认：\(self.cachedDefaultInputName) / \(self.cachedDefaultOutputName)")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsTertiaryText)
                                        .lineLimit(1)
                                }
                            }

                            // REMOVED: Sync mode toggle
                            // Independent mode doesn't work for aggregate devices (Bluetooth, etc.)
                            // due to CoreAudio limitation (OSStatus -10851)
                            // Always use sync mode for reliability across all device types
                        }
                    }
                    .padding(16)
                }

                // Overlay Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("悬浮窗", systemImage: "waveform")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("灵敏度")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("控制音频可视化对声音输入的灵敏程度")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Button("重置") {
                                    self.visualizerNoiseThreshold = 0.4
                                    SettingsStore.shared.visualizerNoiseThreshold = self.visualizerNoiseThreshold
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            HStack(spacing: 10) {
                                Text("更多")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .frame(width: 36, alignment: .trailing)

                                Slider(value: self.$visualizerNoiseThreshold, in: 0.01...0.8, step: 0.01)
                                    .controlSize(.regular)

                                Text("更少")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .frame(width: 36, alignment: .leading)

                                Text(String(format: "%.2f", self.visualizerNoiseThreshold))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(self.settingsTertiaryText)
                                    .frame(width: 36)
                            }

                            Divider().padding(.vertical, 8)

                            // Overlay Position
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("悬浮窗位置")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("录音指示器在屏幕上的显示位置")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Picker("", selection: self.$settings.overlayPosition) {
                                    ForEach(SettingsStore.OverlayPosition.allCases, id: \.self) { position in
                                        Text(position.displayName).tag(position)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170, alignment: .trailing)
                            }

                            Divider().padding(.vertical, 8)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("转录预览长度")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("在刘海/胶囊预览中显示的最近字符数")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Text("\(self.settings.transcriptionPreviewCharLimit) 个字符")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                HStack(spacing: 10) {
                                    Text("较少")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsSecondaryText)
                                        .frame(width: 36, alignment: .trailing)

                                    Slider(
                                        value: Binding(
                                            get: { Double(self.settings.transcriptionPreviewCharLimit) },
                                            set: { self.settings.transcriptionPreviewCharLimit = Int($0.rounded()) }
                                        ),
                                        in: Double(SettingsStore.transcriptionPreviewCharLimitRange.lowerBound)...Double(SettingsStore.transcriptionPreviewCharLimitRange.upperBound),
                                        step: Double(SettingsStore.transcriptionPreviewCharLimitStep)
                                    )
                                    .controlSize(.regular)

                                    Text("较多")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsSecondaryText)
                                        .frame(width: 36, alignment: .leading)
                                }
                            }

                            Divider().padding(.vertical, 4)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(self.settings.overlayPosition == .bottom ? "悬浮窗大小" : "刘海样式")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text(
                                        self.settings.overlayPosition == .bottom
                                            ? "录音指示器的显示大小"
                                            : "选择标准刘海或紧凑布局"
                                    )
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                if self.settings.overlayPosition == .bottom {
                                    Picker("", selection: self.$settings.overlaySize) {
                                        ForEach(SettingsStore.OverlaySize.allCases, id: \.self) { size in
                                            Text(size.displayName).tag(size)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 170, alignment: .trailing)
                                } else {
                                    Picker("", selection: self.$settings.notchPresentationMode) {
                                        ForEach(SettingsStore.NotchPresentationMode.allCases, id: \.self) { mode in
                                            Text(mode.displayName).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 170, alignment: .trailing)
                                }
                            }

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("实时预览")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("说话时在悬浮窗中显示转录文本")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Toggle("", isOn: self.$enableStreamingPreview)
                                    .labelsHidden()
                                    .onChange(of: self.enableStreamingPreview) { _, newValue in
                                        SettingsStore.shared.enableStreamingPreview = newValue
                                    }
                            }

                            // Bottom overlay specific settings (only show when bottom is selected)
                            if self.settings.overlayPosition == .bottom {
                                Divider().padding(.vertical, 4)

                                // Bottom Offset
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("底部偏移")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("距离屏幕底部的距离")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    HStack(spacing: 6) {
                                        Slider(value: self.$settings.overlayBottomOffset, in: 20...500)
                                            .frame(width: 110)
                                            .controlSize(.small)

                                        Text("\(Int(self.settings.overlayBottomOffset)) px")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(self.settingsSecondaryText)
                                            .frame(width: 54, alignment: .trailing)
                                    }
                                    .frame(width: 170, alignment: .trailing)
                                }
                            }

                            if self.asr.isRunning {
                                Text("录音期间设置不可用")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .italic()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(16)
                }

                // Backup & Restore Card
                ThemedCard(style: .standard) {
                    self.backupUtilityRow()
                        .padding(16)
                }

                // Debug Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("调试设置", systemImage: "ladybug.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 8) {
                            self.settingsToggleRow(
                                title: "在应用内显示调试日志",
                                description: "文件日志始终会被收集用于诊断。",
                                isOn: Binding(
                                    get: { SettingsStore.shared.enableDebugLogs },
                                    set: { SettingsStore.shared.enableDebugLogs = $0 }
                                )
                            )

                            Divider().padding(.vertical, 8)

                            Button {
                                let url = FileLogger.shared.currentLogFileURL()
                                if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else {
                                    DebugLogger.shared.info("Log file not found at \(url.path)", source: "SettingsView")
                                }
                            } label: {
                                Label("显示日志文件", systemImage: "doc.richtext")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Text("调试日志包含应用操作的详细信息，可帮助排查问题。")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)
                            Text("崩溃诊断信息默认写入 Library/Logs/Fluid/Fluid.log。")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)

                            #if DEBUG
                            Divider().padding(.vertical, 8)

                            Button(role: .destructive) {
                                self.settings.resetOnboardingProgress()
                                DebugLogger.shared.info("Developer action: onboarding reset", source: "SettingsView")
                            } label: {
                                Label("重置新手引导（开发）", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Text("仅开发者可用。立即重新进入首次运行的新手引导流程。")
                                .font(.caption)
                                .foregroundStyle(self.settingsSecondaryText)
                            #endif
                        }
                    }
                    .padding(16)
                }

                // Experimental Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("实验性设置", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("听写处理速度")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                }

                                Spacer()

                                Picker("", selection: Binding(
                                    get: {
                                        self.settings.selectedSpeechModel.supportsFastDictationProcessing
                                            ? self.settings.parakeetFinalizationMode
                                            : .stableFullFinal
                                    },
                                    set: { mode in
                                        if self.settings.selectedSpeechModel.supportsFastDictationProcessing {
                                            self.settings.parakeetFinalizationMode = mode
                                        }
                                    }
                                )) {
                                    ForEach(ParakeetFinalizationMode.allCases) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170, alignment: .trailing)
                                .disabled(self.asr.isRunning || !self.settings.selectedSpeechModel.supportsFastDictationProcessing)
                            }

                            Text(self.settings.selectedSpeechModel.supportsFastDictationProcessing ? "标准：最可靠。快速：更快但可能不够准确。" : "快速处理适用于 Parakeet TDT v2 和 v3。")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)

                            if self.asr.isRunning {
                                Text("录音期间设置不可用")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .italic()
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .padding(16)
        }
        .sheet(isPresented: self.$showAnalyticsPrivacy) {
            AnalyticsPrivacyView()
                .frame(minWidth: 520, minHeight: 520)
                .appTheme(self.theme)
        }
        .sheet(isPresented: self.analyticsConfirmationBinding) {
            AnalyticsConfirmationView(
                onConfirm: {
                    if let pending = pendingAnalyticsValue {
                        self.shareAnonymousAnalytics = pending
                        self.applyAnalyticsConsentChange(pending)
                    }
                    self.pendingAnalyticsValue = nil
                    self.showAreYouSureToStopAnalytics = false
                },
                onCancel: {
                    self.pendingAnalyticsValue = nil
                    self.showAreYouSureToStopAnalytics = false
                }
            )
        }
        .onAppear {
            Task { @MainActor in
                // Ensure the shared audio startup gate is scheduled. Safe to call repeatedly.
                await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
                await AudioStartupGate.shared.waitUntilOpen()

                self.refreshDevices()

                // Sync input device selection after refresh
                if !self.inputDevices.isEmpty {
                    let inputValid = self.inputDevices.contains { $0.uid == self.selectedInputUID }
                    if !inputValid || self.selectedInputUID.isEmpty {
                        if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid,
                           self.inputDevices.contains(where: { $0.uid == defaultUID })
                        {
                            self.selectedInputUID = defaultUID
                        } else {
                            self.selectedInputUID = self.inputDevices.first?.uid ?? ""
                        }
                    }
                }

                // Sync output device selection after refresh
                if !self.outputDevices.isEmpty {
                    let outputValid = self.outputDevices.contains { $0.uid == self.selectedOutputUID }
                    if !outputValid || self.selectedOutputUID.isEmpty {
                        if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                           self.outputDevices.contains(where: { $0.uid == prefUID })
                        {
                            self.selectedOutputUID = prefUID
                        } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                                  self.outputDevices.contains(where: { $0.uid == defaultUID })
                        {
                            self.selectedOutputUID = defaultUID
                        } else {
                            self.selectedOutputUID = self.outputDevices.first?.uid ?? ""
                        }
                    }
                }

                // CRITICAL FIX: Populate cached default device names after onAppear, not during view body evaluation.
                // This avoids the CoreAudio/SwiftUI AttributeGraph race condition that causes EXC_BAD_ACCESS.
                self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""
                self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                self.refreshRollbackState()
                self.settings.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
                self.refreshAudioHistoryUsage()
            }
        }
        .onChange(of: self.visualizerNoiseThreshold) { _, newValue in
            SettingsStore.shared.visualizerNoiseThreshold = newValue
        }
    }

    private func refreshRollbackState() {
        self.rollbackVersion = SimpleUpdater.shared.latestRollbackVersion() ?? ""
    }

    private func openIssueReportingPage() {
        guard let url = URL(string: "https://github.com/altic-dev/Fluid-oss/issues/new/choose") else { return }
        NSWorkspace.shared.open(url)
    }

    private func exportBackup() {
        do {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = BackupService.shared.suggestedFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let document = BackupService.shared.makeBackupDocument()
            let data = try BackupService.shared.encode(document)
            try data.write(to: url, options: .atomic)

            self.presentInfoAlert(
                title: "备份已导出",
                message: "FluidVoice 备份已保存至：\n\(url.path)"
            )
        } catch {
            self.presentErrorAlert(
                title: "备份导出失败",
                message: error.localizedDescription
            )
        }
    }

    private func importBackup() {
        do {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let data = try Data(contentsOf: url)
            let document = try BackupService.shared.decode(data)

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let confirm = NSAlert()
            confirm.messageText = "导入此备份？"
            confirm.informativeText = """
            这将替换您当前的设置、提示词配置和统计历史。

            导出时间：\(formatter.string(from: document.exportedAt))
            不包含 API 密钥，也不会更改 API 密钥。
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "导入")
            confirm.addButton(withTitle: "取消")

            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            try BackupService.shared.restore(document)
            self.syncLocalSettingsAfterBackupRestore()

            self.presentInfoAlert(
                title: "备份已导入",
                message: "您的设置、提示词配置和统计数据已成功恢复。"
            )
        } catch {
            self.presentErrorAlert(
                title: "备份导入失败",
                message: error.localizedDescription
            )
        }
    }

    private func syncLocalSettingsAfterBackupRestore() {
        self.shareAnonymousAnalytics = SettingsStore.shared.shareAnonymousAnalytics
        self.pendingAnalyticsValue = nil
        self.showAreYouSureToStopAnalytics = false
        self.refreshAudioHistoryUsage()
    }

    private func refreshAudioHistoryUsage() {
        self.audioHistoryUsageBytes = DictationAudioHistoryStore.shared.audioUsageBytes()
        self.audioHistoryBudgetText = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    }

    private func applyAudioHistoryBudget() {
        let normalized = self.audioHistoryBudgetText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else {
            self.presentErrorAlert(title: "预算无效", message: "请输入一个大于零的 GB 数值。")
            self.refreshAudioHistoryUsage()
            return
        }

        let newBudget = max(0.1, value)
        let newBudgetBytes = DictationAudioHistoryStore.bytes(forGigabytes: newBudget)
        if self.audioHistoryUsageBytes > newBudgetBytes {
            let confirm = NSAlert()
            confirm.messageText = "裁剪已保存的音频？"
            confirm.informativeText = """
            此预算低于当前音频用量。FluidVoice 将优先删除最旧的已保存音频，并保留转录历史。
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "应用并裁剪")
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else {
                self.refreshAudioHistoryUsage()
                return
            }
        }

        SettingsStore.shared.audioHistoryBudgetGB = newBudget
        let pruned = TranscriptionHistoryStore.shared.pruneAudioToBudget()
        self.refreshAudioHistoryUsage()
        if pruned > 0 {
            self.presentInfoAlert(title: "音频已裁剪", message: "已从 \(pruned) 条历史记录中删除最旧的已保存音频。")
        }
    }

    private func deleteSavedAudio() {
        let confirm = NSAlert()
        confirm.messageText = "删除已保存的音频？"
        confirm.informativeText = "仅删除已保存的听写音频，转录历史保持完整。"
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "删除音频")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let removed = TranscriptionHistoryStore.shared.deleteAllSavedAudio()
        self.refreshAudioHistoryUsage()
        self.presentInfoAlert(title: "音频已删除", message: "已从 \(removed) 条历史记录中移除音频。")
    }

    private func exportAudioZip() {
        do {
            guard TranscriptionHistoryStore.shared.entries.contains(where: {
                DictationAudioHistoryStore.shared.audioFileExists(for: $0)
            }) else {
                throw DictationAudioHistoryError.noAudioEntries
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = DictationAudioHistoryStore.shared.suggestedAudioExportFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try DictationAudioHistoryStore.shared.exportAudioArchive(
                entries: TranscriptionHistoryStore.shared.entries,
                to: url
            )
            self.presentInfoAlert(title: "音频导出已保存", message: "听写音频导出已保存至：\n\(url.path)")
        } catch {
            self.presentErrorAlert(title: "音频导出失败", message: error.localizedDescription)
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func openPreviousBuildPicker() {
        Task { @MainActor in
            do {
                let options = try await SimpleUpdater.shared.fetchRecentReleaseBuildOptions(
                    owner: "altic-dev",
                    repo: "Fluid-oss",
                    limit: 3,
                    includePrerelease: SettingsStore.shared.betaReleasesEnabled
                )
                self.presentPreviousBuildPicker(options)
            } catch {
                self.openAllReleasesPage()
            }
        }
    }

    private func presentPreviousBuildPicker(_ options: [SimpleUpdater.ReleaseBuildOption]) {
        guard !options.isEmpty else {
            self.openAllReleasesPage()
            return
        }

        let picker = NSAlert()
        picker.messageText = "下载历史版本"
        picker.informativeText = "未找到本地回滚备份。请选择一个近期发布版本："
        picker.alertStyle = .informational

        for option in options {
            picker.addButton(withTitle: option.version)
        }
        picker.addButton(withTitle: "所有版本")
        picker.addButton(withTitle: "取消")

        let response = picker.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = response.rawValue - first

        if index >= 0, index < options.count {
            NSWorkspace.shared.open(options[index].url)
            return
        }
        if index == options.count {
            self.openAllReleasesPage()
        }
    }

    private func openAllReleasesPage() {
        guard let url = URL(string: "https://github.com/altic-dev/Fluid-oss/releases") else { return }
        NSWorkspace.shared.open(url)
    }

    private func applyAnalyticsConsentChange(_ enabled: Bool) {
        SettingsStore.shared.shareAnonymousAnalytics = enabled
        AnalyticsService.shared.setEnabled(enabled)
        AnalyticsService.shared.capture(.analyticsConsentChanged, properties: ["enabled": enabled])
    }

    // MARK: - Helper Views

    private func settingsToggleRow(
        title: String,
        description: String,
        footnote: String? = nil,
        errorMessage: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text(description)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                }

                Spacer()

                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
                    .labelsHidden()
            }

            if let footnote = footnote {
                Text(footnote)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private func backupUtilityRow() -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("备份与恢复")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.settingsTitleText)
                Text("导出或导入设置、提示词配置、历史记录和统计数据。不包含 API 密钥。")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Button(action: self.exportBackup) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(self.theme.palette.accent)
                .controlSize(.regular)

                Button(action: self.importBackup) {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    private func audioHistoryControls() -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("音频存储")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("音频历史：\(DictationAudioHistoryStore.formattedGigabytes(self.audioHistoryUsageBytes)) / \(Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)) GB 上限")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)

                    ProgressView(value: self.audioHistoryUsageFraction())
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                }

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    Text("上限")
                        .font(.caption)
                        .foregroundStyle(self.settingsSecondaryText)

                    TextField("4", text: self.$audioHistoryBudgetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)

                    Text("GB")
                        .font(.caption)
                        .foregroundStyle(self.settingsSecondaryText)

                    Button("应用") {
                        self.applyAudioHistoryBudget()
                    }
                    .controlSize(.small)
                }
            }

            Divider().opacity(0.2)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("导出音频")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("包含 manifest.jsonl 和 WAV 音频的 ZIP 文件。")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                }

                Spacer(minLength: 16)

                Button {
                    self.exportAudioZip()
                } label: {
                    Label("导出 ZIP", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    self.deleteSavedAudio()
                } label: {
                    Label("删除音频", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(self.audioHistoryUsageBytes <= 0)
            }
        }
    }

    private static func audioBudgetText(for value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private func audioHistoryUsageFraction() -> Double {
        let budget = SettingsStore.shared.audioHistoryBudgetBytes
        guard budget > 0 else { return 0 }
        return min(1, Double(self.audioHistoryUsageBytes) / Double(budget))
    }

    private func optionToggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.settingsTitleText)
                Text(description)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .labelsHidden()
        }
    }

    private func instructionsBox(
        title: String,
        steps: [String],
        warningStyle: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                    .font(.caption)
                Text(title)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.settingsTitleText)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption)
                            .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                            .fontWeight(.semibold)
                            .frame(width: 16, alignment: .trailing)
                        Text(.init(step))
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((warningStyle ? self.theme.palette.warning : self.theme.palette.accent).opacity(0.12))
        )
    }

    @ViewBuilder
    private func primaryDictationShortcutsList() -> some View {
        let addTarget = ShortcutRecordingTarget.primaryDictation(.add)
        let isAdding = self.isRecording(addTarget)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(self.settingsSecondaryText)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text("主听写快捷键")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("可使用任意键盘快捷键、附加鼠标按键或修饰点击。")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    if isAdding {
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = nil
                    } else {
                        DebugLogger.shared.debug("Starting to record new primary dictation shortcut", source: "SettingsView")
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = addTarget
                    }
                } label: {
                    Label(isAdding ? "取消" : "添加快捷键", systemImage: isAdding ? "xmark" : "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isAdding && self.isRecordingAnyShortcut)
            }

            ForEach(Array(self.primaryDictationShortcuts.enumerated()), id: \.offset) { index, shortcut in
                self.primaryDictationShortcutRow(shortcut: shortcut, index: index)
            }

            if isAdding {
                self.primaryDictationShortcutCaptureStatus(for: addTarget)
            }
        }
    }

    @ViewBuilder
    private func primaryDictationShortcutRow(shortcut: HotkeyShortcut, index: Int) -> some View {
        let target = ShortcutRecordingTarget.primaryDictation(.replace(index))
        let isRecording = self.isRecording(target)

        HStack(spacing: 10) {
            Color.clear
                .frame(width: 20)

            if isRecording {
                self.shortcutCapturePill()
            } else {
                self.shortcutDisplayPill(shortcut.displayString)
            }

            Button(isRecording ? "取消" : "更改") {
                if isRecording {
                    self.shortcutRecordingMessage = nil
                    self.activeShortcutRecordingTarget = nil
                } else {
                    DebugLogger.shared.debug("Starting to record replacement primary dictation shortcut", source: "SettingsView")
                    self.shortcutRecordingMessage = nil
                    self.activeShortcutRecordingTarget = target
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isRecording && self.isRecordingAnyShortcut)

            Button("移除") {
                guard self.primaryDictationShortcuts.count > 1,
                      self.primaryDictationShortcuts.indices.contains(index)
                else { return }
                self.primaryDictationShortcuts.remove(at: index)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(self.primaryDictationShortcuts.count <= 1 || self.isRecordingAnyShortcut)

            if isRecording,
               let recordingMessage = self.shortcutRecordingMessage,
               !recordingMessage.isEmpty
            {
                Text(recordingMessage)
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private func primaryDictationShortcutCaptureStatus(for target: ShortcutRecordingTarget) -> some View {
        HStack(spacing: 10) {
            Color.clear
                .frame(width: 20)

            self.shortcutCapturePill()

            if self.isRecording(target),
               let recordingMessage = self.shortcutRecordingMessage,
               !recordingMessage.isEmpty
            {
                Text(recordingMessage)
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private func shortcutCapturePill() -> some View {
        Text("请按下快捷键…")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.orange.opacity(0.2))
            )
    }

    private func shortcutDisplayPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(.primary.opacity(0.15), lineWidth: 1)
                    )
            )
    }

    @ViewBuilder
    private func shortcutRow(
        content: ShortcutRowContent,
        shortcut: HotkeyShortcut?,
        isRecording: Bool,
        isAnyRecordingActive: Bool,
        recordingMessage: String? = nil,
        isEnabled: Binding<Bool>? = nil,
        requiresShortcutToEnable: Bool = false,
        onChangePressed: @escaping () -> Void,
        onRemovePressed: (() -> Void)? = nil
    ) -> some View {
        let enabledValue = isEnabled?.wrappedValue ?? true
        let hasShortcut = shortcut != nil
        let enableToggleDisabled = isAnyRecordingActive || (requiresShortcutToEnable && !hasShortcut)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: content.icon)
                    .foregroundStyle(content.iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text(content.description)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                if let isEnabled {
                    Toggle("", isOn: isEnabled)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .disabled(enableToggleDisabled)
                }
            }

            HStack(spacing: 10) {
                Color.clear
                    .frame(width: 20)

                if isRecording {
                    self.shortcutCapturePill()
                } else {
                    self.shortcutDisplayPill(shortcut?.displayString ?? "未设置")
                }

                Button(isRecording ? "取消" : "更改") {
                    if isRecording {
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = nil
                    } else {
                        onChangePressed()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isRecording && (isAnyRecordingActive || (!enabledValue && hasShortcut)))

                if let onRemovePressed {
                    Button("移除") {
                        onRemovePressed()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hasShortcut || isAnyRecordingActive)
                }

                if isRecording, let recordingMessage, !recordingMessage.isEmpty {
                    Text(recordingMessage)
                        .font(.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }
            }
        }
        .opacity(enabledValue ? 1 : 0.7)
    }
}

private final class SettingsPersistentScroller: NSScroller {
    override static var isCompatibleWithOverlayScrollers: Bool {
        false
    }
}

private struct SettingsPersistentScrollView<Content: View>: NSViewRepresentable {
    private let theme: AppTheme
    private let colorScheme: ColorScheme
    private let content: Content

    init(theme: AppTheme, colorScheme: ColorScheme, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.colorScheme = colorScheme
        self.content = content()
    }

    private var hostedContent: AnyView {
        AnyView(
            self.content
                .appTheme(self.theme)
                .environment(\.colorScheme, self.colorScheme)
        )
    }

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScroller = SettingsPersistentScroller()
        scrollView.verticalScroller?.isHidden = false
        scrollView.verticalScroller?.alphaValue = 1
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        let hostingView = NSHostingView(rootView: self.hostedContent)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentHuggingPriority(.required, for: .vertical)

        scrollView.documentView = hostingView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        (scrollView.documentView as? NSHostingView<AnyView>)?.rootView = self.hostedContent
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        if !(scrollView.verticalScroller is SettingsPersistentScroller) {
            scrollView.verticalScroller = SettingsPersistentScroller()
        }
        scrollView.verticalScroller?.isHidden = false
        scrollView.verticalScroller?.alphaValue = 1
    }
}

// MARK: - Filler Words Editor

struct FillerWordsEditor: View {
    @State private var fillerWords: [String] = SettingsStore.shared.fillerWords
    @State private var newWord: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("要移除的填充词：")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(.secondary)

            // Word chips
            FlowLayout(spacing: 6) {
                ForEach(self.fillerWords, id: \.self) { word in
                    HStack(spacing: 4) {
                        Text(word)
                            .font(.caption)
                        Button {
                            self.removeWord(word)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                    )
                }
            }

            // Add new word
            HStack(spacing: 8) {
                TextField("添加词语", text: self.$newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit { self.addWord() }

                Button("添加") { self.addWord() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(self.newWord.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()

                Button("重置") {
                    self.fillerWords = SettingsStore.defaultFillerWords
                    SettingsStore.shared.fillerWords = self.fillerWords
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func addWord() {
        let word = self.newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !self.fillerWords.contains(word) else { return }
        self.fillerWords.append(word)
        SettingsStore.shared.fillerWords = self.fillerWords
        self.newWord = ""
    }

    private func removeWord(_ word: String) {
        self.fillerWords.removeAll { $0 == word }
        SettingsStore.shared.fillerWords = self.fillerWords
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    struct Cache {
        var sizes: [CGSize] = []
        var positions: [CGPoint] = []
        var containerSize: CGSize = .zero
        var lastWidth: CGFloat = 0
    }

    var spacing: CGFloat = 8

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: Array(repeating: .zero, count: subviews.count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        self.arrangeSubviews(proposal: proposal, subviews: subviews, cache: &cache)
        return cache.containerSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        self.arrangeSubviews(proposal: proposal, subviews: subviews, cache: &cache)
        for (index, position) in cache.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let proposedWidth = proposal.width ?? 0
        let maxWidth = proposedWidth > 0 ? proposedWidth : 260
        let needsLayout = cache.positions.count != subviews.count || cache.lastWidth != maxWidth

        if needsLayout {
            cache.positions = []
            cache.positions.reserveCapacity(subviews.count)
            cache.sizes = Array(repeating: .zero, count: subviews.count)
        }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size: CGSize
            if needsLayout {
                size = subviews[index].sizeThatFits(.unspecified)
                cache.sizes[index] = size
            } else {
                size = cache.sizes[index]
            }

            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + self.spacing
                rowHeight = 0
            }
            if needsLayout {
                cache.positions.append(CGPoint(x: x, y: y))
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + self.spacing
        }

        cache.containerSize = CGSize(width: maxWidth, height: y + rowHeight)
        cache.lastWidth = maxWidth
    }
}

// MARK: - Analytics modal confirmation

struct AnalyticsConfirmationView: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme

    private var contactInfoText: AttributedString {
        var text = AttributedString(
            "如有任何疑虑，欢迎随时联系我们，请发送邮件至 alticdev@gmail.com 或在我们的 GitHub 提交 Issue。"
        )

        if let emailRange = text.range(of: "alticdev@gmail.com") {
            text[emailRange].link = URL(string: "mailto:alticdev@gmail.com")
            text[emailRange].foregroundColor = self.theme.palette.accent
        }

        if let githubRange = text.range(of: "GitHub") {
            text[githubRange].link = URL(string: "https://github.com/altic-dev/FluidVoice")
            text[githubRange].foregroundColor = self.theme.palette.accent
        }

        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确定要停止分享匿名统计数据吗？")
                .font(.headline)

            Text("通过分享匿名使用数据，您帮助我们打造您最关心的功能。我们绝不收集任何个人信息（音频、转录文本等）。您的支持仅用于让 FluidVoice 更好地服务于您。")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(.secondary)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.theme.palette.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)
                )

            Text(self.contactInfoText)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Divider()

            HStack {
                Spacer()

                Button("取消") {
                    self.onCancel()
                }

                Button("是") {
                    self.onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
