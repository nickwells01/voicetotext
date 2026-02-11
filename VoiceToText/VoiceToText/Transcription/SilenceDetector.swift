import Foundation

// MARK: - Silence Detector

/// Simple energy-based voice activity detector.
/// Returns true when RMS energy has been below threshold for longer than the configured duration.
final class SilenceDetector {
    private let energyThreshold: Float
    private let silenceDurationMs: Int
    private var silenceStartMs: Int?

    init(energyThreshold: Float = 0.01, silenceDurationMs: Int = 900) {
        self.energyThreshold = energyThreshold
        self.silenceDurationMs = silenceDurationMs
    }

    /// Update with new audio samples and current absolute timestamp.
    /// Returns true if silence has been detected for longer than the configured duration.
    func update(samples: [Float], currentAbsMs: Int) -> Bool {
        guard !samples.isEmpty else { return false }

        let rms = computeRMS(samples)

        if rms < energyThreshold {
            if silenceStartMs == nil {
                silenceStartMs = currentAbsMs
            }
            if let start = silenceStartMs, (currentAbsMs - start) >= silenceDurationMs {
                return true
            }
        } else {
            silenceStartMs = nil
        }

        return false
    }

    func reset() {
        silenceStartMs = nil
    }

    // MARK: - Internal

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        return (sumSquares / Float(samples.count)).squareRoot()
    }
}
