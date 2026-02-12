import XCTest
@testable import VoiceToText

final class SilenceDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Create an array of identical samples. A single-value array [v] has RMS = |v|.
    private func constantSamples(_ value: Float, count: Int = 1) -> [Float] {
        [Float](repeating: value, count: count)
    }

    // MARK: - Empty Input

    func testEmptySamplesReturnsFalse() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 900)
        let result = detector.update(samples: [], currentAbsMs: 0)
        XCTAssertFalse(result)
    }

    // MARK: - Silence Detection

    func testAllZeroSamplesAboveDuration() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 900)

        // First call at t=0 starts silence tracking
        let first = detector.update(samples: constantSamples(0.0), currentAbsMs: 0)
        XCTAssertFalse(first, "Should not be silent yet at t=0")

        // Second call at t=1000 — 1000ms of silence, exceeds 900ms threshold
        let second = detector.update(samples: constantSamples(0.0), currentAbsMs: 1000)
        XCTAssertTrue(second, "Should detect silence after 1000ms of zeros")
    }

    func testRMSBelowThresholdInsufficientDuration() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 900)

        // Start at t=0
        let first = detector.update(samples: constantSamples(0.005), currentAbsMs: 0)
        XCTAssertFalse(first)

        // Only 500ms later — not enough for 900ms threshold
        let second = detector.update(samples: constantSamples(0.005), currentAbsMs: 500)
        XCTAssertFalse(second, "500ms is less than 900ms silenceDuration, should not trigger")
    }

    func testRMSAboveThresholdNeverSilent() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 900)

        // Loud samples (RMS = 0.5) across a long time span
        for ms in stride(from: 0, through: 5000, by: 250) {
            let result = detector.update(samples: constantSamples(0.5), currentAbsMs: ms)
            XCTAssertFalse(result, "Loud samples should never trigger silence at t=\(ms)")
        }
    }

    // MARK: - Threshold Boundary

    func testExactThresholdBoundaryNotSilent() {
        let threshold: Float = 0.01
        let detector = SilenceDetector(energyThreshold: threshold, silenceDurationMs: 100)

        // A single sample of 0.01 has RMS = 0.01 which equals the threshold.
        // Since the check is `rms < energyThreshold` (strictly less than),
        // exactly equal should NOT count as silent.
        let first = detector.update(samples: [threshold], currentAbsMs: 0)
        XCTAssertFalse(first)

        let second = detector.update(samples: [threshold], currentAbsMs: 500)
        XCTAssertFalse(second, "RMS exactly at threshold should not be considered silent")
    }

    // MARK: - Reset

    func testResetClearsSilenceTracking() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 500)

        // Start accumulating silence
        detector.update(samples: constantSamples(0.0), currentAbsMs: 0)
        detector.update(samples: constantSamples(0.0), currentAbsMs: 400)

        // Reset mid-silence
        detector.reset()

        // Continue with silence — counter should have restarted
        let result = detector.update(samples: constantSamples(0.0), currentAbsMs: 800)
        XCTAssertFalse(result, "After reset, silence counter should restart from this call")

        // Now enough time passes from the new start (800ms) to exceed 500ms
        let later = detector.update(samples: constantSamples(0.0), currentAbsMs: 1400)
        XCTAssertTrue(later, "Should detect silence 600ms after reset-restart")
    }

    // MARK: - lastRMS

    func testLastRMSUpdatesAfterEachCall() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 900)

        XCTAssertEqual(detector.lastRMS, 0, "Initial lastRMS should be 0")

        // Feed a single sample of 0.5 → RMS = 0.5
        detector.update(samples: [0.5], currentAbsMs: 0)
        XCTAssertEqual(detector.lastRMS, 0.5, accuracy: 1e-6)

        // Feed a single sample of 0.0 → RMS = 0.0
        detector.update(samples: [0.0], currentAbsMs: 100)
        XCTAssertEqual(detector.lastRMS, 0.0, accuracy: 1e-6)
    }

    // MARK: - Alternating Loud / Silent

    func testAlternatingLoudSilentResetsCounter() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 500)

        // Silent at t=0
        detector.update(samples: constantSamples(0.0), currentAbsMs: 0)
        // Loud at t=300 — resets silence counter
        detector.update(samples: constantSamples(0.5), currentAbsMs: 300)
        // Silent at t=600 — silence counter restarts here
        detector.update(samples: constantSamples(0.0), currentAbsMs: 600)
        // Loud at t=900 — resets silence counter again
        detector.update(samples: constantSamples(0.5), currentAbsMs: 900)
        // Silent at t=1200
        let result = detector.update(samples: constantSamples(0.0), currentAbsMs: 1200)
        XCTAssertFalse(result, "Alternating loud/silent should keep resetting the counter")

        // Not enough continuous silence yet — only at t=1200 restart
        let later = detector.update(samples: constantSamples(0.0), currentAbsMs: 1500)
        XCTAssertFalse(later, "Only 300ms of continuous silence since t=1200")

        // Now 500ms of continuous silence from t=1200
        let enough = detector.update(samples: constantSamples(0.0), currentAbsMs: 1700)
        XCTAssertTrue(enough, "500ms of continuous silence from t=1200 should trigger")
    }

    // MARK: - Custom Configuration

    func testCustomThresholdAndDurationRespected() {
        let detector = SilenceDetector(energyThreshold: 0.1, silenceDurationMs: 200)

        // RMS = 0.05 is below custom threshold of 0.1
        detector.update(samples: [0.05], currentAbsMs: 0)
        let tooEarly = detector.update(samples: [0.05], currentAbsMs: 100)
        XCTAssertFalse(tooEarly, "100ms < 200ms custom duration")

        let enough = detector.update(samples: [0.05], currentAbsMs: 200)
        XCTAssertTrue(enough, "200ms >= 200ms custom duration with RMS below custom threshold")
    }
}
