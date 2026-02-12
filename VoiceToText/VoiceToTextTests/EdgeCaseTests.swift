import XCTest
@testable import VoiceToText

final class EdgeCaseTests: XCTestCase {

    // MARK: - Helpers

    private func makeToken(_ text: String, startMs: Int, endMs: Int, prob: Float = 0.9) -> TranscriptionToken {
        TranscriptionToken(text: text, startTimeMs: startMs, endTimeMs: endMs, probability: prob)
    }

    private func makeSegment(_ text: String, startMs: Int, endMs: Int, tokens: [TranscriptionToken]) -> TranscriptionSegment {
        TranscriptionSegment(text: text, startTimeMs: startMs, endTimeMs: endMs, tokens: tokens)
    }

    private func makeResult(segments: [TranscriptionSegment], windowStartAbsMs: Int) -> DecodeResult {
        DecodeResult(segments: segments, windowStartAbsMs: windowStartAbsMs)
    }

    private func makeSimpleResult(_ text: String, windowStartAbsMs: Int = 0) -> DecodeResult {
        let seg = makeSegment(text, startMs: 0, endMs: 1000, tokens: [])
        return makeResult(segments: [seg], windowStartAbsMs: windowStartAbsMs)
    }

    // MARK: - Empty and Minimal Audio

    func testEmptyAudioProducesEmptyTranscript() {
        let stabilizer = TranscriptStabilizer()

        // No decodes at all — state should remain empty
        XCTAssertTrue(stabilizer.state.rawCommitted.isEmpty)
        XCTAssertTrue(stabilizer.state.rawSpeculative.isEmpty)
    }

    func testVeryShortAudio100ms() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 900)

        // 100ms at 16kHz = 1600 samples of low-level noise
        let samples = (0..<1600).map { _ in Float.random(in: -0.001...0.001) }
        let result = detector.update(samples: samples, currentAbsMs: 100)

        // Should not crash, and 100ms is well below silenceDurationMs of 900ms
        XCTAssertFalse(result)
    }

    func testExactlyOneSecondAudio() {
        let buffer = AudioRingBuffer(capacity: 16000, sampleRate: 16000)

        // 16000 samples = exactly 1 second at 16kHz
        let samples = [Float](repeating: 0.1, count: 16000)
        buffer.append(samples: samples)

        let window = buffer.getWindow()
        XCTAssertFalse(window.pcm.isEmpty)
        XCTAssertEqual(window.pcm.count, 16000)
    }

    // MARK: - Silence Handling

    func testAllSilentAudioEmptyTranscript() {
        let stabilizer = TranscriptStabilizer()

        // No updates at all — finalizeAll on empty state
        let state = stabilizer.finalizeAll()
        XCTAssertTrue(state.rawCommitted.isEmpty)
        XCTAssertTrue(state.rawSpeculative.isEmpty)
    }

    func testSilenceDetectorWithZeroSamples() {
        let detector = SilenceDetector(energyThreshold: 0.01, silenceDurationMs: 900)

        // Empty array should not crash and should return false
        let result = detector.update(samples: [], currentAbsMs: 0)
        XCTAssertFalse(result)
    }

    // MARK: - Stabilizer Edge Cases

    func testEmptyDecodeResult() {
        let stabilizer = TranscriptStabilizer()

        // DecodeResult with no segments
        let result = makeResult(segments: [], windowStartAbsMs: 0)
        let state = stabilizer.update(decodeResult: result, windowEndAbsMs: 1000, commitMarginMs: 300)

        // No crash, state unchanged
        XCTAssertTrue(state.rawCommitted.isEmpty)
        XCTAssertTrue(state.rawSpeculative.isEmpty)
    }

    func testDecodeResultWithEmptySegmentText() {
        let stabilizer = TranscriptStabilizer()

        // Segment with empty text and no tokens
        let seg = makeSegment("", startMs: 0, endMs: 500, tokens: [])
        let result = makeResult(segments: [seg], windowStartAbsMs: 0)
        let state = stabilizer.update(decodeResult: result, windowEndAbsMs: 1000, commitMarginMs: 300)

        // No crash, state unchanged
        XCTAssertTrue(state.rawCommitted.isEmpty)
        XCTAssertTrue(state.rawSpeculative.isEmpty)
    }

    func testConflictingDecodeResults() {
        let stabilizer = TranscriptStabilizer()

        // First decode: "Hello world"
        let res1 = makeSimpleResult("Hello world")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        // Second decode: agrees on "Hello"
        let res2 = makeSimpleResult("Hello world")
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        let committedAfterAgreement = stabilizer.state.rawCommitted
        XCTAssertTrue(committedAfterAgreement.contains("Hello"))

        // Third decode: completely different text
        let res3 = makeSimpleResult("Something entirely new and different")
        stabilizer.update(decodeResult: res3, windowEndAbsMs: 1500, commitMarginMs: 300)

        // Previously committed "Hello" should be preserved
        XCTAssertTrue(stabilizer.state.rawCommitted.contains("Hello"))
        XCTAssertGreaterThanOrEqual(stabilizer.state.rawCommitted.count, committedAfterAgreement.count)
    }

    func testCommittedTextMonotonicallyGrows() {
        let stabilizer = TranscriptStabilizer()

        var previousCommittedCount = 0

        for i in 0..<10 {
            let words = (0...i).map { "word\($0)" }.joined(separator: " ")
            let result = makeSimpleResult(words)
            stabilizer.update(decodeResult: result, windowEndAbsMs: i * 250, commitMarginMs: 300)

            let currentCount = stabilizer.state.rawCommitted.count
            XCTAssertGreaterThanOrEqual(
                currentCount,
                previousCommittedCount,
                "rawCommitted.count decreased from \(previousCommittedCount) to \(currentCount) at tick \(i)"
            )
            previousCommittedCount = currentCount
        }
    }

    // MARK: - Hallucination Detection

    func testHallucinationLoopDetected() {
        let stabilizer = TranscriptStabilizer()

        // Build tokens with a repeating 4-word phrase: "A cup of coffee A cup of coffee"
        let tokens = [
            makeToken(" A", startMs: 0, endMs: 100, prob: 0.9),
            makeToken(" cup", startMs: 100, endMs: 200, prob: 0.9),
            makeToken(" of", startMs: 200, endMs: 300, prob: 0.9),
            makeToken(" coffee", startMs: 300, endMs: 400, prob: 0.9),
            makeToken(" A", startMs: 400, endMs: 500, prob: 0.9),
            makeToken(" cup", startMs: 500, endMs: 600, prob: 0.9),
            makeToken(" of", startMs: 600, endMs: 700, prob: 0.9),
            makeToken(" coffee", startMs: 700, endMs: 800, prob: 0.9),
        ]
        let seg = makeSegment("A cup of coffee A cup of coffee", startMs: 0, endMs: 800, tokens: tokens)
        let result = makeResult(segments: [seg], windowStartAbsMs: 0)

        // First decode
        stabilizer.update(decodeResult: result, windowEndAbsMs: 1000, commitMarginMs: 300)

        // Second decode (same) to trigger agreement
        stabilizer.update(decodeResult: result, windowEndAbsMs: 1250, commitMarginMs: 300)

        let fullText = stabilizer.state.fullRawText

        // "cup of coffee" should not appear twice consecutively
        let occurrences = fullText.components(separatedBy: "cup of coffee").count - 1
        XCTAssertLessThanOrEqual(occurrences, 1, "Hallucination loop should be truncated — found \(occurrences) occurrences of 'cup of coffee' in: \(fullText)")
    }

    // MARK: - Low Probability Token Filtering

    func testLowProbabilityTokensFiltered() {
        let stabilizer = TranscriptStabilizer()

        let tokens = [
            makeToken(" Hello", startMs: 0, endMs: 200, prob: 0.95),
            makeToken(" world", startMs: 200, endMs: 400, prob: 0.85),
            makeToken(" garbage", startMs: 400, endMs: 600, prob: 0.05),  // below threshold
            makeToken(" noise", startMs: 600, endMs: 800, prob: 0.02),    // below threshold
        ]
        let seg = makeSegment("Hello world garbage noise", startMs: 0, endMs: 800, tokens: tokens)
        let result = makeResult(segments: [seg], windowStartAbsMs: 0)

        let state = stabilizer.update(decodeResult: result, windowEndAbsMs: 1000, commitMarginMs: 300)

        // Low-probability tokens should be filtered out
        let fullText = state.fullRawText
        XCTAssertFalse(fullText.contains("garbage"), "Low-probability token 'garbage' should be filtered out, got: \(fullText)")
        XCTAssertFalse(fullText.contains("noise"), "Low-probability token 'noise' should be filtered out, got: \(fullText)")
        // High-probability tokens should survive
        XCTAssertTrue(fullText.contains("Hello"), "High-probability 'Hello' should survive")
        XCTAssertTrue(fullText.contains("world"), "High-probability 'world' should survive")
    }

    // MARK: - Trim and Long Session

    func testTrimAtSentenceBoundary() {
        let stabilizer = TranscriptStabilizer()

        // Build committed text with two agreeing decodes
        let res1 = makeSimpleResult("Hello world. This is a test.")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeSimpleResult("Hello world. This is a test.")
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        XCTAssertFalse(stabilizer.state.previousDecodeRawWords.isEmpty)

        // Simulate trim notification
        stabilizer.notifyTrimmed()

        // After trim, LA-2 state should be cleared
        XCTAssertTrue(stabilizer.state.previousDecodeRawWords.isEmpty)
        XCTAssertTrue(stabilizer.state.previousDecodeNormalizedWords.isEmpty)
    }

    func testLongSessionAccumulation() {
        let stabilizer = TranscriptStabilizer()

        // Simulate 60 ticks of varying decodes
        for i in 0..<60 {
            let text = "Word\(i) continues here"
            let result = makeSimpleResult(text)
            stabilizer.update(decodeResult: result, windowEndAbsMs: i * 250, commitMarginMs: 300)
        }

        // Verify no crash and state is consistent
        let fullText = stabilizer.state.fullRawText
        XCTAssertFalse(fullText.isEmpty, "After 60 ticks, fullRawText should not be empty")

        // Committed + speculative should form valid text (no corruption)
        let committed = stabilizer.state.rawCommitted
        let speculative = stabilizer.state.rawSpeculative
        XCTAssertFalse(committed.contains("  "), "No double spaces in committed text")
        if !speculative.isEmpty {
            XCTAssertFalse(speculative.contains("  "), "No double spaces in speculative text")
        }
    }

    // MARK: - Unicode

    func testUnicodeSurvivesPipeline() {
        let stabilizer = TranscriptStabilizer()

        // Two agreeing decodes with emoji
        let res1 = makeSimpleResult("Hello 🌍 world")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeSimpleResult("Hello 🌍 world")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        let fullText = state.fullRawText
        XCTAssertTrue(fullText.contains("🌍"), "Emoji should be preserved in output, got: \(fullText)")
    }

    func testCJKCharactersSurvive() {
        let stabilizer = TranscriptStabilizer()

        let res1 = makeSimpleResult("Hello 你好 world")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeSimpleResult("Hello 你好 world")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        let fullText = state.fullRawText
        XCTAssertTrue(fullText.contains("你好"), "CJK characters should be preserved, got: \(fullText)")
    }

    func testDiacriticsSurvive() {
        let stabilizer = TranscriptStabilizer()

        let res1 = makeSimpleResult("café résumé naïve")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeSimpleResult("café résumé naïve")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        let fullText = state.fullRawText
        XCTAssertTrue(fullText.contains("café"), "Diacritics should be preserved, got: \(fullText)")
        XCTAssertTrue(fullText.contains("résumé"), "Diacritics should be preserved, got: \(fullText)")
        XCTAssertTrue(fullText.contains("naïve"), "Diacritics should be preserved, got: \(fullText)")
    }
}
