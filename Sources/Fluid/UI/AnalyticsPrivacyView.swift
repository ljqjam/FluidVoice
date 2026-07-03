import SwiftUI

struct AnalyticsPrivacyView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("匿名统计数据")
                        .font(.system(size: 18, weight: .semibold))
                    Text("启用统计数据后 FluidVoice 收集的内容")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("完成") { self.dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider().opacity(0.4)

            self.contactInfoView

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    self.sectionTitle("我们收集的内容")
                    self.bullet("基本应用/设备信息（应用版本、macOS 版本、CPU 系列/芯片类别等）")
                    self.bullet("使用了哪些功能（例如：听写、命令模式等）")
                    self.bullet("性能指标，如转录块延迟和 AI 后处理延迟（毫秒）。")
                    self.bullet("模型/提供商元数据及后处理输入长度（仅字符数，不含文本内容）。")
                    self.bullet("功能是否正常运行及高层次错误信息。")

                    self.sectionTitle("我们不收集的内容")
                    self.bullet("任何转录文本或音频。")
                    self.bullet("所选文本、改写提示词或 AI 回复。")
                    self.bullet("命令模式中的终端命令或输出。")
                    self.bullet("窗口标题、应用名称、文件名/路径、剪贴板内容或您输入的任何内容。")

                    self.sectionTitle("如何使用这些数据")
                    self.bullet("了解哪些功能正在被使用，以及可以在哪些方面提升可靠性和性能。")
                    self.bullet("衡量产品健康度（如活跃设备数、留存率），无需用户注册账号。")

                    self.sectionTitle("控制权")
                    self.bullet("您可以随时在设置 → 分享匿名统计数据中关闭统计功能。")
                }
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(self.theme.palette.contentBackground)
    }

    private var contactInfoView: some View {
        Text(self.contactInfoText)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.theme.palette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)
            )
    }

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

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(self.theme.palette.accent)
            .padding(.top, 4)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}
