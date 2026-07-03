import Foundation

enum ParakeetFinalizationMode: String, CaseIterable, Codable, Identifiable {
    case stableFullFinal
    case tokenTimedChunkMerge

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .stableFullFinal:
            return "标准"
        case .tokenTimedChunkMerge:
            return "快速"
        }
    }

    var detailText: String {
        switch self {
        case .stableFullFinal:
            return "最为可靠。"
        case .tokenTimedChunkMerge:
            return "更快速，但可能不够准确。"
        }
    }
}
