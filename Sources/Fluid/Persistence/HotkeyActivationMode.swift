import Foundation

enum HotkeyActivationMode: String, Codable, CaseIterable, Identifiable {
    case toggle, hold, automatic

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .toggle: return "切换"
        case .hold: return "按住"
        case .automatic: return "自动（两者）"
        }
    }

    var description: String {
        switch self {
        case .toggle: return "点按一次开始，再次点按停止。"
        case .hold: return "仅在按住快捷键时录音。"
        case .automatic: return "点按切换，按住即可按住说话。"
        }
    }
}
