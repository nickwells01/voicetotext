import XCTest
@testable import VoiceToText

/// Robustness tests for the transcript stabilizer under competitive quality scenarios:
/// long sessions, varied commit patterns, hallucination defense, and streaming vs finalize.
final class StabilizerRobustnessTests: XCTestCase {

    // MARK: - Helpers

    private func makeSegment(_ text: String, startMs: Int, endMs: Int, tokens: [TranscriptionToken] = []) -> TranscriptionSegment {
        TranscriptionSegment(text: text, startTimeMs: startMs, endTimeMs: endMs, tokens: tokens)
    }

    private func makeSimpleResult(_ text: String, windowStartAbsMs: Int = 0) -> DecodeResult {
        let seg = makeSegment(text, startMs: 0, endMs: 1000)
        return DecodeResult(segments: [seg], windowStartAbsMs: windowStartAbsMs)
    }

    private func makeTokenResult(tokens: [TranscriptionToken], windowStartAbsMs: Int = 0) -> DecodeResult {
        let text = tokens.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let endMs = tokens.last?.endTimeMs ?? 1000
        let seg = TranscriptionSegment(text: text, startTimeMs: 0, endTimeMs: endMs, tokens: tokens)
        return DecodeResult(segments: [seg], windowStartAbsMs: windowStartAbsMs)
    }

    // MARK: - Long-Session Stability

    func testLongSessionCommittedNeverShrinks100Ticks() {
        let stabilizer = TranscriptStabilizer()
        let baseWords = (1...120).map { "word\($0)" }

        var previousLength = 0

        for tick in 0..<100 {
            let wordCount = min(tick + 3, baseWords.count)
            let text = baseWords[0..<wordCount].joined(separator: " ")
            let result = makeSimpleResult(text, windowStartAbsMs: tick * 250)
            stabilizer.update(decodeResult: result, windowEndAbsMs: (tick + 1) * 250, commitMarginMs: 0)

            let currentLength = stabilizer.state.rawCommitted.count
            XCTAssertGreaterThanOrEqual(currentLength, previousLength,
                "Committed text shrank at tick \(tick): \(previousLength) -> \(currentLength)")
            previousLength = currentLength
        }

        // After 100 ticks, committed text should have substantial content
        XCTAssertGreaterThan(stabilizer.state.committedWordCount, 50,
            "100 progressive ticks should commit at least 50 words")
    }

    func testLongSessionNoDuplicateWords() {
        let stabilizer = TranscriptStabilizer()
        let baseWords = (1...120).map { "word\($0)" }

        for tick in 0..<100 {
            let wordCount = min(tick + 3, baseWords.count)
            let text = baseWords[0..<wordCount].joined(separator: " ")
            let result = makeSimpleResult(text, windowStartAbsMs: tick * 250)
            stabilizer.update(decodeResult: result, windowEndAbsMs: (tick + 1) * 250, commitMarginMs: 0)
        }

        let words = stabilizer.state.rawCommitted
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0).lowercased() }

        for i in 0..<(words.count - 1) {
            XCTAssertNotEqual(words[i], words[i + 1],
                "Consecutive duplicate '\(words[i])' found at index \(i)")
        }
    }

    func testTrimNotificationResetsAgreement() {
        let stabilizer = TranscriptStabilizer()

        // Build up LA-2 state
        let res1 = makeSimpleResult("Hello world foo bar")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 0)
        let res2 = makeSimpleResult("Hello world foo bar")
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 0)

        XCTAssertFalse(stabilizer.state.previousDecodeRawWords.isEmpty)

        // Trim notification should clear LA-2 comparison state
        stabilizer.notifyTrimmed()

        XCTAssertTrue(stabilizer.state.previousDecodeRawWords.isEmpty)
        XCTAssertTrue(stabilizer.state.previousDecodeNormalizedWords.isEmpty)

        // Committed text should be preserved
        XCTAssertFalse(stabilizer.state.rawCommitted.isEmpty)
    }

    func testRapidResetCycle() {
        let stabilizer = TranscriptStabilizer()

        for i in 0..<50 {
            let result = makeSimpleResult("Text for cycle \(i)")
            stabilizer.update(decodeResult: result, windowEndAbsMs: i * 100, commitMarginMs: 0)

            stabilizer.reset()

            XCTAssertTrue(stabilizer.state.rawCommitted.isEmpty,
                "Committed not clean after reset \(i)")
            XCTAssertTrue(stabilizer.state.rawSpeculative.isEmpty,
                "Speculative not clean after reset \(i)")
            XCTAssertTrue(stabilizer.state.previousDecodeRawWords.isEmpty,
                "LA-2 state not clean after reset \(i)")
        }
    }

    // MARK: - Streaming vs Finalize Quality

    func testFinalizeAlwaysProducesSupersetOfCommitted() {
        let stabilizer = TranscriptStabilizer()
        let baseWords = (1...30).map { "word\($0)" }

        for tick in 0..<20 {
            let wordCount = min(tick + 3, baseWords.count)
            let text = baseWords[0..<wordCount].joined(separator: " ")
            let result = makeSimpleResult(text, windowStartAbsMs: tick * 250)
            stabilizer.update(decodeResult: result, windowEndAbsMs: (tick + 1) * 250, commitMarginMs: 0)
        }

        let preFinalizeWords = Set(
            stabilizer.state.rawCommitted.lowercased()
                .split(separator: " ").map(String.init)
        )

        stabilizer.finalizeAll()

        let postFinalizeWords = Set(
            stabilizer.state.rawCommitted.lowercased()
                .split(separator: " ").map(String.init)
        )

        for word in preFinalizeWords {
            XCTAssertTrue(postFinalizeWords.contains(word),
                "Word '\(word)' from committed text missing after finalization")
        }
    }

    func testFinalizeStripsTrailingFragments() {
        let stabilizer = TranscriptStabilizer()
        stabilizer.state.rawCommitted = "Hello world. The"

        stabilizer.finalizeAll()

        XCTAssertEqual(stabilizer.state.rawCommitted, "Hello world.")
    }

    func testFinalizeRunsFullDeduplication() {
        let stabilizer = TranscriptStabilizer()
        // 4-word non-consecutive repeat
        stabilizer.state.rawCommitted = "alpha beta the cat jumps over delta the cat jumps over gamma"

        stabilizer.finalizeAll()

        let words = stabilizer.state.rawCommitted
            .split(separator: " ").map { String($0).lowercased() }

        var count = 0
        for i in 0..<words.count where i + 3 < words.count {
            if words[i] == "the" && words[i+1] == "cat"
                && words[i+2] == "jumps" && words[i+3] == "over" {
                count += 1
            }
        }
        XCTAssertEqual(count, 1,
            "Non-consecutive repeat should be removed by finalize full dedup")
    }

    // MARK: - Hallucination Defense

    func testHallucinationLoopDetectedAt3Words() {
        let stabilizer = TranscriptStabilizer()

        // Tokens forming a 3-word loop: "apple banana cherry apple banana cherry"
        // The loop detector should trim the repeated occurrence during extraction.
        let tokens = [
            TranscriptionToken(text: " apple", startTimeMs: 0, endTimeMs: 100, probability: 0.9),
            TranscriptionToken(text: " banana", startTimeMs: 100, endTimeMs: 200, probability: 0.9),
            TranscriptionToken(text: " cherry", startTimeMs: 200, endTimeMs: 300, probability: 0.9),
            TranscriptionToken(text: " apple", startTimeMs: 300, endTimeMs: 400, probability: 0.9),
            TranscriptionToken(text: " banana", startTimeMs: 400, endTimeMs: 500, probability: 0.9),
            TranscriptionToken(text: " cherry", startTimeMs: 500, endTimeMs: 600, probability: 0.9),
        ]
        let result = makeTokenResult(tokens: tokens)

        // Two identical decodes to get committed text
        stabilizer.update(decodeResult: result, windowEndAbsMs: 600, commitMarginMs: 0)
        stabilizer.update(decodeResult: result, windowEndAbsMs: 850, commitMarginMs: 0)

        // "apple" should appear only once (loop was trimmed during extraction)
        let words = stabilizer.state.fullRawText
            .split(separator: " ").map { String($0).lowercased() }
        let appleCount = words.filter { $0 == "apple" }.count

        XCTAssertEqual(appleCount, 1,
            "3-word hallucination loop should be trimmed to single occurrence")
    }

    func testLowProbTokenStopsAccumulation() {
        let stabilizer = TranscriptStabilizer()

        // 4 high-probability tokens followed by 1 low-probability "hallucination"
        let tokens = [
            TranscriptionToken(text: " Hello", startTimeMs: 0, endTimeMs: 100, probability: 0.9),
            TranscriptionToken(text: " world", startTimeMs: 100, endTimeMs: 200, probability: 0.9),
            TranscriptionToken(text: " this", startTimeMs: 200, endTimeMs: 300, probability: 0.9),
            TranscriptionToken(text: " is", startTimeMs: 300, endTimeMs: 400, probability: 0.9),
            TranscriptionToken(text: " garbage", startTimeMs: 400, endTimeMs: 500, probability: 0.05),
        ]
        let result = makeTokenResult(tokens: tokens)

        stabilizer.update(decodeResult: result, windowEndAbsMs: 500, commitMarginMs: 0)
        stabilizer.update(decodeResult: result, windowEndAbsMs: 750, commitMarginMs: 0)

        let fullText = stabilizer.state.fullRawText
        XCTAssertFalse(fullText.lowercased().contains("garbage"),
            "Low-probability token should be filtered out")
        XCTAssertTrue(fullText.contains("Hello"),
            "High-probability tokens should be preserved")
    }

    func testConsecutiveDuplicateRemoval() {
        let stabilizer = TranscriptStabilizer()
        stabilizer.state.rawCommitted = "the the dog dog"

        stabilizer.finalizeAll()

        XCTAssertEqual(stabilizer.state.rawCommitted, "the dog")
    }
}
