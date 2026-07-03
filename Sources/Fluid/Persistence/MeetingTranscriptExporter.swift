import Foundation

/// Exports meeting transcripts as plain-text files under `~/Documents/FluidVoiceOutput` so users can
/// read and manage them outside the app (the in-app history lives in UserDefaults). Only live-meeting
/// transcripts are exported today. File names are derived deterministically from the entry's display
/// name so a later delete can find and remove the matching file.
enum MeetingTranscriptExporter {
    static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidVoiceOutput", isDirectory: true)
    }

    /// Turns a display name into a filesystem-safe base file name (no extension).
    static func fileName(for displayName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let safe = displayName
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "transcript" : safe
    }

    /// Writes `text` to `<directory>/<displayName>.txt`. Returns the URL, or nil on empty text/failure.
    @discardableResult
    static func export(text: String, displayName: String) -> URL? {
        guard let directory else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(self.fileName(for: displayName)).txt")
            try Data(trimmed.utf8).write(to: url, options: .atomic)
            DebugLogger.shared.info("Exported transcript to \(url.path)", source: "MeetingTranscriptExporter")
            return url
        } catch {
            DebugLogger.shared.warning("Transcript export failed: \(error)", source: "MeetingTranscriptExporter")
            return nil
        }
    }

    /// Removes the exported file matching a display name (no-op if it doesn't exist).
    static func delete(displayName: String) {
        guard let directory else { return }
        let url = directory.appendingPathComponent("\(self.fileName(for: displayName)).txt")
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes all exported `.txt` files, leaving any unrelated user files in the folder intact.
    static func deleteAll() {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.pathExtension.lowercased() == "txt" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
