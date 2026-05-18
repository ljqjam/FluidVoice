import Foundation

enum ParakeetFinalizationMode: String, CaseIterable, Codable, Identifiable {
    case stableFullFinal
    case tokenTimedChunkMerge

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .stableFullFinal:
            return "Normal"
        case .tokenTimedChunkMerge:
            return "Fast"
        }
    }

    var detailText: String {
        switch self {
        case .stableFullFinal:
            return "Most reliable and standard."
        case .tokenTimedChunkMerge:
            return "Faster, but maybe inaccurate."
        }
    }
}
