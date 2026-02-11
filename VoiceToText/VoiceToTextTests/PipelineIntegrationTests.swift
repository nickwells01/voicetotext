import XCTest
@testable import VoiceToText

/// Integration tests verifying the stabilizer + ring buffer work together
/// with simulated decode results (no actual Whisper inference).
final class PipelineIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeToken(_ text: String, startMs: Int, endMs: Int) -> TranscriptionToken {
        TranscriptionToken(text: text, startTimeMs: startMs, endTimeMs: endMs, probability: 0.95)
    }

    // MARK: - Sliding Window Simulation

    func testSlidingWindowProgressiveCommit() {
        let config = PipelineConfig()
        let stabilizer = TranscriptStabilizer()
        let ringBuffer = AudioRingBuffer(capacity: config.windowSamples, sampleRate: config.sampleRate)

        // Simulate 3 seconds of audio arriving
        let totalSamples = config.sampleRate * 3 // 3s
        let samples = [Float](repeating: 0.1, count: totalSamples)
        ringBuffer.append(samples: samples)

        // Simulate decode result from a window
        let window = ringBuffer.getWindow()
        let tokens = [
            makeToken(" The", startMs: 0, endMs: 500),
            makeToken(" quick", startMs: 500, endMs: 1200),
            makeToken(" brown", startMs: 1200, endMs: 2000),
            makeToken(" fox", startMs: 2000, endMs: 2700),
        ]
        let segment = TranscriptionSegment(
            text: "The quick brown fox",
            startTimeMs: 0,
            endTimeMs: 2700,
            tokens: tokens
        )
        let result = DecodeResult(segments: [segment], windowStartAbsMs: window.windowStartAbsMs)

        let state = stabilizer.update(
            decodeResult: result,
            windowEndAbsMs: window.windowEndAbsMs,
            commitMarginMs: config.commitMarginMs
        )

        // With 3s window and 700ms margin, horizon at ~2300ms
        // Tokens ending before horizon should be committed
        XCTAssertFalse(state.rawCommitted.isEmpty, "Some tokens should be committed")
        // fox ends at 2700 > horizon, should be speculative
        XCTAssertTrue(state.fullRawText.contains("fox"))
    }

    // MARK: - Multi-Tick Simulation

    func testMultipleTicksAccumulateText() {
        let stabilizer = TranscriptStabilizer()

        // Tick 1: window 0-2000ms
        let tokens1 = [
            makeToken(" Hello", startMs: 0, endMs: 500),
            makeToken(" world", startMs: 500, endMs: 1200),
            makeToken(" how", startMs: 1200, endMs: 1800),
        ]
        let seg1 = TranscriptionSegment(text: "Hello world how", startTimeMs: 0, endTimeMs: 1800, tokens: tokens1)
        let res1 = DecodeResult(segments: [seg1], windowStartAbsMs: 0)
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 2000, commitMarginMs: 700)

        let afterTick1 = stabilizer.state.rawCommitted

        // Tick 2: window 500-3000ms (overlapping)
        let tokens2 = [
            makeToken(" world", startMs: 0, endMs: 700),   // abs: 500-1200 (overlap)
            makeToken(" how", startMs: 700, endMs: 1300),   // abs: 1200-1800 (overlap)
            makeToken(" are", startMs: 1300, endMs: 1800),  // abs: 1800-2300
            makeToken(" you", startMs: 1800, endMs: 2300),  // abs: 2300-2800
        ]
        let seg2 = TranscriptionSegment(text: "world how are you", startTimeMs: 0, endTimeMs: 2300, tokens: tokens2)
        let res2 = DecodeResult(segments: [seg2], windowStartAbsMs: 500)
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 3000, commitMarginMs: 700)

        // Committed text should grow monotonically
        XCTAssertGreaterThanOrEqual(stabilizer.state.rawCommitted.count, afterTick1.count)
        // Should contain both early and later words
        let fullText = stabilizer.state.fullRawText
        XCTAssertTrue(fullText.contains("Hello"))
    }

    // MARK: - Finalization

    func testFinalizationCommitsAll() {
        let stabilizer = TranscriptStabilizer()

        let tokens = [
            makeToken(" Testing", startMs: 0, endMs: 300),
            makeToken(" finalization", startMs: 300, endMs: 700),
        ]
        let seg = TranscriptionSegment(text: "Testing finalization", startTimeMs: 0, endTimeMs: 700, tokens: tokens)
        let result = DecodeResult(segments: [seg], windowStartAbsMs: 0)

        // Large margin — everything speculative
        stabilizer.update(decodeResult: result, windowEndAbsMs: 700, commitMarginMs: 1000)
        XCTAssertFalse(stabilizer.state.rawSpeculative.isEmpty)

        // Finalize with margin=0
        stabilizer.update(decodeResult: result, windowEndAbsMs: 700, commitMarginMs: 0)
        stabilizer.finalizeAll()

        XCTAssertTrue(stabilizer.state.rawSpeculative.isEmpty)
        XCTAssertTrue(stabilizer.state.rawCommitted.contains("Testing"))
        XCTAssertTrue(stabilizer.state.rawCommitted.contains("finalization"))
    }

    // MARK: - Silence Detector

    func testSilenceDetectorDetectsSilence() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 500)

        // Feed silent samples for 600ms
        let silentSamples = [Float](repeating: 0.001, count: 1600) // 100ms at 16kHz
        for i in 0..<6 {
            let isSilent = detector.update(samples: silentSamples, currentAbsMs: i * 100)
            if i >= 5 {
                XCTAssertTrue(isSilent, "Should detect silence after 500ms")
            }
        }
    }

    func testSilenceDetectorResetsOnSpeech() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 500)

        // 400ms of silence
        let silent = [Float](repeating: 0.001, count: 1600)
        for i in 0..<4 {
            _ = detector.update(samples: silent, currentAbsMs: i * 100)
        }

        // Then speech — should reset
        let speech = [Float](repeating: 0.5, count: 1600)
        let afterSpeech = detector.update(samples: speech, currentAbsMs: 400)
        XCTAssertFalse(afterSpeech)

        // Another 400ms of silence — not yet enough
        for i in 0..<4 {
            let result = detector.update(samples: silent, currentAbsMs: 500 + i * 100)
            XCTAssertFalse(result, "Should not detect silence yet after speech break")
        }
    }
}
