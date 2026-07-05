import Combine
import Foundation

/// Runs on-demand, per-session refinement of a finished live-meeting transcript. For each retained
/// utterance it re-transcribes the audio with FireRedASR and replaces that line's text in place,
/// preserving timestamps and order, then overwrites the saved history entry and its exported `.txt`.
///
/// Refinement can be triggered repeatedly while the session's audio is retained (7 days). It reuses
/// the shared ASR serialization queue so its CoreML work never overlaps live dictation/meeting decode.
@MainActor
final class MeetingRefinementService: ObservableObject {
    static let shared = MeetingRefinementService()

    @Published private(set) var refiningEntryID: UUID?
    @Published private(set) var progressText: String = ""

    private init() {}

    var isRefining: Bool { self.refiningEntryID != nil }

    /// Refines the session identified by `entryID`. No-op if already refining, if the session has no
    /// retained/expired audio, or if the FireRedASR model is missing.
    func refine(entryID: UUID, asrService: ASRService) async {
        guard self.refiningEntryID == nil else { return }
        guard MeetingRefinementStore.shared.canRefine(entryID: entryID),
              let record = MeetingRefinementStore.shared.record(for: entryID)
        else {
            return
        }

        self.refiningEntryID = entryID
        self.progressText = "正在准备精修模型…"
        defer {
            self.refiningEntryID = nil
            self.progressText = ""
        }

        let fireRed = FireRedAsrProvider()
        do {
            try await fireRed.prepare(progressHandler: nil)
        } catch {
            DebugLogger.shared.warning("Meeting refinement setup failed: \(error)", source: "MeetingRefinementService")
            return
        }

        var refinedTexts: [UUID: String] = [:]
        let segments = record.segments.sorted { $0.startTime < $1.startTime }
        let total = segments.count
        for (index, segment) in segments.enumerated() {
            self.progressText = "正在精修转录…（\(index + 1)/\(total)）"
            let samples = MeetingRefinementStore.shared.samples(entryID: entryID, segment: segment)
            guard !samples.isEmpty else { continue }
            do {
                let result = try await asrService.runSerializedTranscription { [samples] in
                    try await fireRed.transcribeFinal(samples)
                }
                let refined = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !refined.isEmpty {
                    refinedTexts[segment.lineID] = refined
                }
            } catch {
                DebugLogger.shared.warning("Meeting per-utterance refinement failed: \(error)", source: "MeetingRefinementService")
            }
        }

        guard !refinedTexts.isEmpty else { return }
        MeetingRefinementStore.shared.updateSegmentTexts(entryID: entryID, texts: refinedTexts)

        // Rebuild the `[MM:SS] text` transcript from the (now refined) segments, ordered by start time.
        let finalText = segments
            .map { segment in
                let text = refinedTexts[segment.lineID] ?? segment.text
                return "[\(LiveMeetingTranscriptionService.formatTimestamp(segment.startTime))] \(text)"
            }
            .joined(separator: "\n")

        FileTranscriptionHistoryStore.shared.updateText(id: entryID, text: finalText)
        if let entry = FileTranscriptionHistoryStore.shared.entries.first(where: { $0.id == entryID }) {
            MeetingTranscriptExporter.export(text: finalText, displayName: entry.fileName)
        }
        DebugLogger.shared.info("Meeting refinement completed for entry \(entryID)", source: "MeetingRefinementService")
    }
}
