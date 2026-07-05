import Foundation

/// One retained utterance of a live-meeting session: its line identity, start time (seconds from
/// session start), current text, and the on-disk file holding the raw 16 kHz mono Float32 samples
/// used to re-transcribe (refine) it later.
struct MeetingRefinementSegment: Codable, Equatable {
    let lineID: UUID
    let startTime: TimeInterval
    var text: String
    let audioFileName: String
}

/// Per-session refinement record, keyed to the `FileTranscriptionEntry` produced when the meeting
/// stopped. Retains the utterance audio so the user can trigger on-demand FireRedASR refinement from
/// the history list within the retention window.
struct MeetingRefinementRecord: Codable, Equatable {
    let entryID: UUID
    let endDate: Date
    var segments: [MeetingRefinementSegment]
}

/// Persists live-meeting per-utterance audio to disk so refinement can run on demand (and repeatedly)
/// after the session ends, surviving app restarts. Audio is kept for `retention` (7 days) then cleaned
/// up automatically; it is also removed when the owning history entry is deleted.
///
/// Mirrors `DictationAudioHistoryStore`'s on-disk layout, but stores lossless raw Float32 samples
/// (`.f32`) instead of WAV so refinement reads back exactly what was captured with no extra parsing.
final class MeetingRefinementStore: @unchecked Sendable {
    static let shared = MeetingRefinementStore()

    /// Retention window after a meeting ends. Retained audio is refinable until this elapses.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let appSupportFolder = "FluidVoice"
    private let audioFolder = "MeetingRefinementAudio"
    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard
    private let indexKey = "MeetingRefinementRecords"
    private let lock = NSLock()

    private init() {}

    // MARK: - Save

    /// Persists the retained utterances for a finished session under `entryID`, writing one `.f32` file
    /// per utterance and recording metadata. No-op when `segments` is empty.
    func save(
        entryID: UUID,
        endDate: Date,
        segments: [(lineID: UUID, startTime: TimeInterval, text: String, samples: [Float])]
    ) {
        guard !segments.isEmpty else { return }
        guard let directory = try? self.sessionDirectory(entryID: entryID, createIfNeeded: true) else {
            DebugLogger.shared.warning("Could not create refinement audio directory", source: "MeetingRefinementStore")
            return
        }

        var storedSegments: [MeetingRefinementSegment] = []
        for segment in segments {
            let fileName = "\(segment.lineID.uuidString).f32"
            let url = directory.appendingPathComponent(fileName, isDirectory: false)
            do {
                try Self.data(from: segment.samples).write(to: url, options: .atomic)
            } catch {
                DebugLogger.shared.warning("Failed to write refinement audio: \(error)", source: "MeetingRefinementStore")
                continue
            }
            storedSegments.append(MeetingRefinementSegment(
                lineID: segment.lineID,
                startTime: segment.startTime,
                text: segment.text,
                audioFileName: fileName
            ))
        }

        guard !storedSegments.isEmpty else { return }
        let record = MeetingRefinementRecord(entryID: entryID, endDate: endDate, segments: storedSegments)
        self.mutateRecords { records in
            records.removeAll { $0.entryID == entryID }
            records.append(record)
        }
        DebugLogger.shared.info(
            "Saved \(storedSegments.count) refinement segments for meeting entry \(entryID)",
            source: "MeetingRefinementStore"
        )
    }

    // MARK: - Query

    func record(for entryID: UUID) -> MeetingRefinementRecord? {
        self.loadRecords().first { $0.entryID == entryID }
    }

    /// True when the session still has retained, non-expired audio and the FireRedASR model is present.
    func canRefine(entryID: UUID) -> Bool {
        guard FireRedAsrModelLocator.modelsExist() else { return false }
        guard let record = self.record(for: entryID), !record.segments.isEmpty else { return false }
        return record.endDate.addingTimeInterval(Self.retention) > Date()
    }

    /// Reads back the raw Float32 samples for a segment, or an empty array if the file is missing/unreadable.
    func samples(entryID: UUID, segment: MeetingRefinementSegment) -> [Float] {
        guard let directory = try? self.sessionDirectory(entryID: entryID, createIfNeeded: false) else {
            return []
        }
        let url = directory.appendingPathComponent(segment.audioFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.samples(from: data)
    }

    // MARK: - Mutate

    /// Applies refined text back to the stored segments (by line id) so the record stays in sync with
    /// the refined transcript and can be re-refined later.
    func updateSegmentTexts(entryID: UUID, texts: [UUID: String]) {
        self.mutateRecords { records in
            guard let index = records.firstIndex(where: { $0.entryID == entryID }) else { return }
            for segmentIndex in records[index].segments.indices {
                let lineID = records[index].segments[segmentIndex].lineID
                if let text = texts[lineID] {
                    records[index].segments[segmentIndex].text = text
                }
            }
        }
    }

    // MARK: - Delete

    /// Removes a session's retained audio and metadata (called when its history entry is deleted).
    func deleteRecord(entryID: UUID) {
        if let directory = try? self.sessionDirectory(entryID: entryID, createIfNeeded: false) {
            try? self.fileManager.removeItem(at: directory)
        }
        self.mutateRecords { records in
            records.removeAll { $0.entryID == entryID }
        }
    }

    /// Removes all retained meeting audio and metadata (called from history "clear all").
    func deleteAll() {
        if let directory = try? self.baseDirectory(createIfNeeded: false),
           self.fileManager.fileExists(atPath: directory.path)
        {
            try? self.fileManager.removeItem(at: directory)
        }
        self.saveRecords([])
    }

    /// Deletes sessions whose retention window has elapsed. Call when the meeting/history UI appears.
    func deleteExpired() {
        let now = Date()
        let expired = self.loadRecords().filter { $0.endDate.addingTimeInterval(Self.retention) <= now }
        guard !expired.isEmpty else { return }
        for record in expired {
            if let directory = try? self.sessionDirectory(entryID: record.entryID, createIfNeeded: false) {
                try? self.fileManager.removeItem(at: directory)
            }
        }
        let expiredIDs = Set(expired.map(\.entryID))
        self.mutateRecords { records in
            records.removeAll { expiredIDs.contains($0.entryID) }
        }
        DebugLogger.shared.info("Cleaned up \(expired.count) expired meeting refinement records", source: "MeetingRefinementStore")
    }

    // MARK: - Index persistence

    private func loadRecords() -> [MeetingRefinementRecord] {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let data = self.defaults.data(forKey: self.indexKey),
              let decoded = try? JSONDecoder().decode([MeetingRefinementRecord].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func saveRecords(_ records: [MeetingRefinementRecord]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let encoded = try? JSONEncoder().encode(records) {
            self.defaults.set(encoded, forKey: self.indexKey)
        }
    }

    private func mutateRecords(_ transform: (inout [MeetingRefinementRecord]) -> Void) {
        var records = self.loadRecords()
        transform(&records)
        self.saveRecords(records)
    }

    // MARK: - Directories

    private func baseDirectory(createIfNeeded: Bool) throws -> URL {
        guard let base = self.fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = base
            .appendingPathComponent(self.appSupportFolder, isDirectory: true)
            .appendingPathComponent(self.audioFolder, isDirectory: true)
        if createIfNeeded {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func sessionDirectory(entryID: UUID, createIfNeeded: Bool) throws -> URL {
        let directory = try self.baseDirectory(createIfNeeded: createIfNeeded)
            .appendingPathComponent(entryID.uuidString, isDirectory: true)
        if createIfNeeded {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    // MARK: - Sample encoding

    private static func data(from samples: [Float]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    private static func samples(from data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self).prefix(count))
        }
    }
}
