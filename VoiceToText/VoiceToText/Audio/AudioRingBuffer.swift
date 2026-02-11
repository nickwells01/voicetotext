import Foundation

// MARK: - Audio Ring Buffer

/// Circular buffer for streaming audio with absolute sample index tracking.
/// Maintains a sliding window of the most recent audio samples and maps
/// buffer positions to absolute millisecond timestamps.
final class AudioRingBuffer {
    private var storage: [Float]
    private let capacity: Int
    private let sampleRate: Int
    private var writeHead: Int = 0
    private(set) var totalSamplesWritten: Int = 0

    init(capacity: Int, sampleRate: Int = 16000) {
        self.capacity = capacity
        self.sampleRate = sampleRate
        self.storage = [Float](repeating: 0, count: capacity)
    }

    // MARK: - Write

    func append(samples: [Float]) {
        for sample in samples {
            storage[writeHead % capacity] = sample
            writeHead = (writeHead + 1) % capacity
        }
        totalSamplesWritten += samples.count
    }

    // MARK: - Read Window

    /// Returns the latest window of audio samples with absolute timestamps.
    /// If fewer samples than capacity have been written, returns all available samples.
    func getWindow() -> (pcm: [Float], windowStartAbsMs: Int, windowEndAbsMs: Int) {
        let available = min(totalSamplesWritten, capacity)
        guard available > 0 else {
            return ([], 0, 0)
        }

        var pcm = [Float](repeating: 0, count: available)

        // Read from ring buffer in order
        let readStart: Int
        if totalSamplesWritten <= capacity {
            readStart = 0
        } else {
            readStart = writeHead  // writeHead points to oldest sample when buffer is full
        }

        for i in 0..<available {
            pcm[i] = storage[(readStart + i) % capacity]
        }

        let windowEndAbsSample = totalSamplesWritten
        let windowStartAbsSample = totalSamplesWritten - available

        return (
            pcm: pcm,
            windowStartAbsMs: sampleIndexToAbsMs(windowStartAbsSample),
            windowEndAbsMs: sampleIndexToAbsMs(windowEndAbsSample)
        )
    }

    // MARK: - Timestamp Conversion

    func sampleIndexToAbsMs(_ sampleIndex: Int) -> Int {
        (sampleIndex * 1000) / sampleRate
    }

    // MARK: - Reset

    func reset() {
        storage = [Float](repeating: 0, count: capacity)
        writeHead = 0
        totalSamplesWritten = 0
    }
}
