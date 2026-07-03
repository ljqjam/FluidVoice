# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

FluidVoice 是一款基于 Swift/SwiftUI 的 macOS 语音转文字听写应用，最低支持 macOS 15.0+。主要面向 Apple Silicon，Intel Mac 仅通过 Whisper 模型支持。依赖管理使用 Swift Package Manager，日常开发在 Xcode 中进行。

## 常用命令

**在 Xcode 中打开（主要开发方式）：**
```bash
open Fluid.xcodeproj
```

**命令行构建（不签名）：**
```bash
xcodebuild -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

**运行全部测试：**
```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

**运行单个测试类：**
```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FluidDictationIntegrationTests/DictationE2ETests
```

**代码检查（提交前必须执行，CI 强制 `--strict`）：**
```bash
swiftlint --strict --config .swiftlint.yml Sources
```

**代码格式化：**
```bash
swiftformat --config .swiftformat Sources
```

**安装 pre-commit hook（防止误提交 Team ID，只需执行一次）：**
```bash
cp scripts/check-team-id.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

Xcode 签名：在 Signing & Capabilities 中选择「Automatically manage signing」并选择个人 Team，配置存储在 `xcuserdata/`（已 gitignore）。

## 架构说明

所有源码位于 `Sources/Fluid/`。App target 名为 `FluidVoice`，测试中模块名为 `FluidVoice_Debug`。

### 入口点

- **`fluidApp.swift`** — `@main` 结构体，将 `AppServices.shared` 和 `MenuBarManager` 作为 `@StateObject` 创建，并将 `SettingsStore.shared` 注入环境。
- **`AppDelegate.swift`** — `NSApplicationDelegate`：处理启动流程（登录项检测、`LocalAPIServer.shared.start()`、Analytics 初始化、更新检查），以及应用退出时对私有 AI 运行时的优雅关闭。
- **`ContentView.swift`** — 根 SwiftUI 视图，包含侧边栏导航（`SidebarItem` 枚举）。首次渲染完成后调用 `AppServices.shared.signalUIReady()`，解除对重型服务初始化的门控。

### Service 层（`Services/`）

所有重型服务均为 `@MainActor` 单例或 Swift actor。**在 `AppServices.shared.signalUIReady()` 触发之前，禁止初始化任何服务**——这是防止 SwiftUI 运行时元数据崩溃的硬性约束。

| 服务 | 职责 |
|---|---|
| `AppServices` | `ASRService` 和 `AudioHardwareObserver` 的懒加载容器，控制启动时序。 |
| `ASRService` | 核心 ASR 管线：音频采集、流式转录、音频电平可视化。使用 `TranscriptionExecutor` actor 序列化 CoreML 操作。 |
| `GlobalHotkeyManager` | 通过 Carbon/AppKit 事件捕获全局快捷键，管理听写/编辑/命令/改写四种 Hold 模式的切换逻辑。 |
| `TypingService` | 通过辅助功能 API 和剪贴板回退，将文字注入任意应用。 |
| `DictationPostProcessingService` | 将原始转录文本路由至云端 AI 提供商或 Fluid Intelligence 进行后处理增强。 |
| `PrivateAIIntegrationService` | Actor，桥接私有 Fluid Intelligence 运行时（不在本仓库中）。运行时缺失时回退至 `UnavailableAIIntegrationShim`。 |
| `MenuBarManager` | 管理 NSStatusItem 及其弹出面板。 |
| `CommandModeService` | 执行语音命令（启动应用、触发快捷指令、系统操作）。 |
| `RewriteModeService` | 处理改写模式：选中文本捕获与原地替换。 |
| `NotchOverlayManager` | 管理实时转录悬浮窗（DynamicNotchKit 或标准窗口）。 |
| `LocalAPIServer` | 基于 NWListener 的本地回环 HTTP API，供 Fluid Intelligence 及外部集成接入，由 `LocalAPIRouter` 路由。 |

### 转录提供商协议（`Services/TranscriptionProvider.swift`）

`TranscriptionProvider` 是对所有语音后端的统一抽象，各实现如下：

- `FluidAudioProvider` — 通过 `FluidAudio` SPM 包支持 Parakeet TDT（v2/v3）和 Nemotron
- `ParakeetRealtimeProvider` — Parakeet Flash 流式识别（超低延迟）
- `NemotronProvider` — Nemotron Speech 3.5
- `WhisperProvider` — 通过 SwiftWhisper 支持 Whisper（兼容 Intel）
- `AppleSpeechProvider` / `AppleSpeechAnalyzerProvider` — macOS 系统内置语音识别
- `ExternalCoreMLTranscriptionProvider` — Cohere 等 CoreML 模型
- `PrivateAIProvider` — Fluid Intelligence 转录路径

### 持久化层（`Persistence/`）

- **`SettingsStore`** — 以 `UserDefaults` 为底层的中央 `ObservableObject` 单例，包含大量 `migrate*IfNeeded()` 迁移方法，API Key 通过 `KeychainService` 存储。
- **`TranscriptionHistoryStore` / `FileTranscriptionHistoryStore`** — 本地听写历史记录。
- **`DictationAudioHistoryStore`** — 可选的音频录音历史，带用量控制。

`SettingsStore` 按功能拆分为多个扩展文件：`+CommandMode`、`+PromptRouting`、`+LaunchAtStartup`、`+NemotronLanguage`。

### 网络层（`Networking/`）

- **`AIProvider` 协议** — `process(systemPrompt:userText:model:apiKey:baseURL:stream:) async -> String`
- **`OpenAICompatibleProvider`** — 实现该协议，支持 OpenAI、Groq 及自定义兼容端点
- **`AppleIntelligenceProvider`** — Apple Intelligence 后端
- **`FunctionCallingProvider`** — 支持 Function Calling 的提供商，用于命令模式
- **`ModelDownloader`** — 从 Hugging Face 下载并缓存语音模型

### UI 结构

- **`UI/`** — 设置面板（`SettingsView`、`AISettingsView` 拆分为 `+SpeechRecognition`、`+AIConfiguration`、`+AdvancedSettings`）、引导步骤、历史记录、统计、自定义词典、反馈。
- **`Views/`** — 录音期间显示的实时悬浮视图：`NotchContentViews`、`CommandModeView`、`RewriteModeView`、`BottomOverlayView`。
- **`Theme/`** — `AppTheme`、`AdaptiveAppTheme`、`ThemeEnvironment`、按钮样式。

### Analytics（`Analytics/`）

基于 PostHog 的可选匿名统计，由 `AnalyticsService.shared` 门控。事件定义在 `AnalyticsEvent.swift`，分桶策略在 `AnalyticsBuckets.swift`。语音音频、转录文本和提示词不会被收集。

## 测试

测试位于 `Tests/FluidDictationIntegrationTests/`，使用 XCTest（非 Swift Testing）。测试 target 通过 `@testable import FluidVoice_Debug` 导入。主要覆盖 `SettingsStore` 的迁移逻辑和 `LLMClient` 的请求构造——测试通过 `withRestoredDefaults(keys:)` 修改并还原 `UserDefaults`。

## 关键约束

- **私有 Fluid Intelligence 运行时不在本仓库**。`PrivateAIIntegrationService` 使用提供商注册表模式：运行时缺失时调用自动回退至 `UnavailableAIIntegrationShim`，开源构建中不可假设其存在。
- **禁止提交 `DEVELOPMENT_TEAM` 改动**（`project.pbxproj`）。pre-commit hook（`scripts/check-team-id.sh`）会强制拦截。
- **`#if arch(arm64)` 编译守卫** 包裹所有 FluidAudio 导入及 CoreML/ANE 相关代码，Intel 构建（Whisper 路径）必须在不进入这些分支的情况下正常编译。
- **启动崩溃防护** — 服务初始化顺序至关重要。重型服务（ASR、音频）必须等到 `ContentView.onAppear` 调用 `AppServices.shared.signalUIReady()` 之后才能创建。
