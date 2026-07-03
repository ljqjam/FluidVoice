import Foundation

/// Mixes two independent 16 kHz mono audio streams (microphone + system audio) into a
/// single real-time-aligned mono stream suitable for the transcription pipeline.
///
/// Both sources arrive asynchronously on different threads. Each source keeps its own FIFO.
/// A wall-clock-driven `pullMixed(elapsedSamples:)` consumes an equal number of samples from
/// each queue (padding with silence when a source is behind), sums them sample-by-sample,
/// and clamps to [-1, 1].
final class LiveAudioMixer {
    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []
    private var consumedSamples: Int = 0
    private let lock = NSLock()

    /// Appends microphone samples (16 kHz mono Float32).
    func appendMic(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        self.lock.lock()
        defer { lock.unlock() }
        self.micQueue.append(contentsOf: samples)
    }

    /// Appends system-audio samples (16 kHz mono Float32).
    func appendSystem(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        self.lock.lock()
        defer { lock.unlock() }
        self.systemQueue.append(contentsOf: samples)
    }

    /// Produces the next block of mixed samples so that the total number of samples emitted
    /// since `reset()` matches `elapsedSamples` (derived from wall-clock time × 16000).
    /// - Parameter elapsedSamples: total samples that should have been emitted by now.
    /// - Returns: the newly mixed mono samples (may be empty).
    func pullMixed(elapsedSamples: Int) -> [Float] {
        self.lock.lock()
        defer { lock.unlock() }

        let wanted = elapsedSamples - self.consumedSamples
        guard wanted > 0 else { return [] }

        var mixed = [Float](repeating: 0, count: wanted)

        let micCount = min(wanted, self.micQueue.count)
        for index in 0..<micCount {
            mixed[index] += self.micQueue[index]
        }

        let sysCount = min(wanted, self.systemQueue.count)
        for index in 0..<sysCount {
            mixed[index] += self.systemQueue[index]
        }

        // Clamp to avoid clipping when both sources are loud simultaneously.
        for index in 0..<wanted {
            if mixed[index] > 1 {
                mixed[index] = 1
            } else if mixed[index] < -1 {
                mixed[index] = -1
            }
        }

        if micCount > 0 {
            self.micQueue.removeFirst(micCount)
        }
        if sysCount > 0 {
            self.systemQueue.removeFirst(sysCount)
        }
        self.consumedSamples += wanted

        return mixed
    }

    /// Clears all buffered audio and resets the timeline.
    func reset() {
        self.lock.lock()
        defer { lock.unlock() }
        self.micQueue.removeAll(keepingCapacity: false)
        self.systemQueue.removeAll(keepingCapacity: false)
        self.consumedSamples = 0
    }
}
