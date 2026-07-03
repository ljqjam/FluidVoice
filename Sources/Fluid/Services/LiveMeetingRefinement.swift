import Foundation

/// Pure decision logic for the live-meeting two-pass refinement, kept free of
/// service dependencies so the branching is unit-testable.
enum LiveMeetingRefinement {
    static func shouldAttempt(cohereInstalled: Bool, audioFileExists: Bool) -> Bool {
        cohereInstalled && audioFileExists
    }

    /// Refined text wins when it has content; otherwise keep the live transcript.
    static func finalTranscript(live: String, refined: String?) -> String {
        guard let refined, !refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return live
        }
        return refined
    }
}
