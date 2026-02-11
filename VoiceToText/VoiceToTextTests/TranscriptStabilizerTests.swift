import XCTest
@testable import VoiceToText

final class TranscriptStabilizerTests: XCTestCase {

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

    // MARK: - Commit Horizon

    func testCommitHorizonCommitsOlderTokens() {
        let stabilizer = TranscriptStabilizer()

        let tokens = [
            makeToken(" Hello", startMs: 0, endMs: 200),
            makeToken(" world", startMs: 200, endMs: 500),
            makeToken(" this", startMs: 500, endMs: 800),
            makeToken(" is", startMs: 800, endMs: 1000),
        ]
        let segment = makeSegment("Hello world this is", startMs: 0, endMs: 1000, tokens: tokens)
        let result = makeResult(segments: [segment], windowStartAbsMs: 0)

        // Window ends at 1000ms, commit margin 300ms → horizon at 700ms
        let state = stabilizer.update(decodeResult: result, windowEndAbsMs: 1000, commitMarginMs: 300)

        // Tokens ending at <=700ms should be committed: "Hello" (200), "world" (500)
        XCTAssertTrue(state.rawCommitted.contains("Hello"))
        XCTAssertTrue(state.rawCommitted.contains("world"))
        // "this" ends at 800 > 700, so speculative
        XCTAssertTrue(state.rawSpeculative.contains("this"))
    }

    // MARK: - Speculative Replacement

    func testSpeculativeTailIsReplacedNotAppended() {
        let stabilizer = TranscriptStabilizer()

        // First decode
        let tokens1 = [
            makeToken(" Hello", startMs: 0, endMs: 200),
            makeToken(" speculative", startMs: 200, endMs: 500),
        ]
        let seg1 = makeSegment("Hello speculative", startMs: 0, endMs: 500, tokens: tokens1)
        let res1 = makeResult(segments: [seg1], windowStartAbsMs: 0)
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 500, commitMarginMs: 300)

        // Second decode with different speculative tail
        let tokens2 = [
            makeToken(" Hello", startMs: 0, endMs: 200),
            makeToken(" actual", startMs: 200, endMs: 400),
            makeToken(" words", startMs: 400, endMs: 600),
        ]
        let seg2 = makeSegment("Hello actual words", startMs: 0, endMs: 600, tokens: tokens2)
        let res2 = makeResult(segments: [seg2], windowStartAbsMs: 0)
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 600, commitMarginMs: 300)

        // "speculative" should be gone, replaced by new speculative
        XCTAssertFalse(state.rawSpeculative.contains("speculative"))
    }

    // MARK: - No Duplicates

    func testNoDuplicatesAcrossOverlappingWindows() {
        let stabilizer = TranscriptStabilizer()

        // First window: 0-1000ms
        let tokens1 = [
            makeToken(" Hello", startMs: 0, endMs: 300),
            makeToken(" world", startMs: 300, endMs: 600),
        ]
        let seg1 = makeSegment("Hello world", startMs: 0, endMs: 600, tokens: tokens1)
        let res1 = makeResult(segments: [seg1], windowStartAbsMs: 0)
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 500)

        // Second window overlapping: 500-1500ms, repeats "world" at different offset
        let tokens2 = [
            makeToken(" world", startMs: 0, endMs: 100), // relative to window start 500, so abs 500-600
            makeToken(" foo", startMs: 100, endMs: 400), // abs 600-900
            makeToken(" bar", startMs: 400, endMs: 800), // abs 900-1300
        ]
        let seg2 = makeSegment("world foo bar", startMs: 0, endMs: 800, tokens: tokens2)
        let res2 = makeResult(segments: [seg2], windowStartAbsMs: 500)
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1500, commitMarginMs: 500)

        // "world" should only appear once in committed
        let worldCount = state.rawCommitted.components(separatedBy: "world").count - 1
        XCTAssertEqual(worldCount, 1, "word 'world' should appear exactly once in committed text")
    }

    // MARK: - Finalize Commits Everything

    func testFinalizeAllCommitsEverything() {
        let stabilizer = TranscriptStabilizer()

        let tokens = [
            makeToken(" Hello", startMs: 0, endMs: 200),
            makeToken(" world", startMs: 200, endMs: 500),
        ]
        let seg = makeSegment("Hello world", startMs: 0, endMs: 500, tokens: tokens)
        let result = makeResult(segments: [seg], windowStartAbsMs: 0)

        // Use large margin so everything is speculative
        stabilizer.update(decodeResult: result, windowEndAbsMs: 500, commitMarginMs: 1000)
        XCTAssertFalse(stabilizer.state.rawSpeculative.isEmpty)

        // Finalize
        let state = stabilizer.finalizeAll()
        XCTAssertTrue(state.rawSpeculative.isEmpty)
        XCTAssertFalse(state.rawCommitted.isEmpty)
    }

    // MARK: - Committed Text Never Shrinks

    func testCommittedTextNeverShrinks() {
        let stabilizer = TranscriptStabilizer()

        // Build up committed text
        let tokens1 = [
            makeToken(" Hello", startMs: 0, endMs: 100),
            makeToken(" world", startMs: 100, endMs: 200),
            makeToken(" this", startMs: 200, endMs: 300),
        ]
        let seg1 = makeSegment("Hello world this", startMs: 0, endMs: 300, tokens: tokens1)
        let res1 = makeResult(segments: [seg1], windowStartAbsMs: 0)
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let committedAfterFirst = stabilizer.state.rawCommitted
        XCTAssertFalse(committedAfterFirst.isEmpty)

        // Second decode with fewer tokens shouldn't shrink committed
        let tokens2 = [
            makeToken(" ok", startMs: 300, endMs: 400),
        ]
        let seg2 = makeSegment("ok", startMs: 300, endMs: 400, tokens: tokens2)
        let res2 = makeResult(segments: [seg2], windowStartAbsMs: 0)
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1000, commitMarginMs: 300)

        XCTAssertGreaterThanOrEqual(stabilizer.state.rawCommitted.count, committedAfterFirst.count)
    }

    // MARK: - Whitespace Normalization

    func testWhitespaceNormalization() {
        let stabilizer = TranscriptStabilizer()

        let tokens = [
            makeToken("  Hello  ", startMs: 0, endMs: 200),
            makeToken("  world  ", startMs: 200, endMs: 400),
        ]
        let seg = makeSegment("Hello world", startMs: 0, endMs: 400, tokens: tokens)
        let result = makeResult(segments: [seg], windowStartAbsMs: 0)
        let state = stabilizer.update(decodeResult: result, windowEndAbsMs: 1000, commitMarginMs: 0)

        // No double spaces
        XCTAssertFalse(state.rawCommitted.contains("  "))
        // No leading/trailing whitespace
        XCTAssertEqual(state.rawCommitted, state.rawCommitted.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Reset

    func testReset() {
        let stabilizer = TranscriptStabilizer()

        let tokens = [makeToken(" Hello", startMs: 0, endMs: 200)]
        let seg = makeSegment("Hello", startMs: 0, endMs: 200, tokens: tokens)
        let result = makeResult(segments: [seg], windowStartAbsMs: 0)
        stabilizer.update(decodeResult: result, windowEndAbsMs: 1000, commitMarginMs: 0)

        XCTAssertFalse(stabilizer.state.rawCommitted.isEmpty)

        stabilizer.reset()

        XCTAssertTrue(stabilizer.state.rawCommitted.isEmpty)
        XCTAssertTrue(stabilizer.state.rawSpeculative.isEmpty)
        XCTAssertEqual(stabilizer.state.committedEndAbsMs, 0)
    }

    // MARK: - Token Spacing

    func testTokenLeadingSpacesPreserved() {
        let stabilizer = TranscriptStabilizer()

        // Whisper tokens typically have leading spaces like " I", " am"
        let tokens = [
            makeToken(" I", startMs: 0, endMs: 100),
            makeToken(" am", startMs: 100, endMs: 200),
            makeToken(" happy", startMs: 200, endMs: 300),
        ]
        let seg = makeSegment(" I am happy", startMs: 0, endMs: 300, tokens: tokens)
        let result = makeResult(segments: [seg], windowStartAbsMs: 0)
        let state = stabilizer.update(decodeResult: result, windowEndAbsMs: 1000, commitMarginMs: 0)

        // Should be "I am happy", not "Iamhappy"
        XCTAssertEqual(state.rawCommitted, "I am happy")
    }

    func testSpeculativeTokenSpacingPreserved() {
        let stabilizer = TranscriptStabilizer()

        let tokens = [
            makeToken(" Hello", startMs: 0, endMs: 200),
            makeToken(" there", startMs: 200, endMs: 500),
            makeToken(" friend", startMs: 500, endMs: 800),
        ]
        let seg = makeSegment(" Hello there friend", startMs: 0, endMs: 800, tokens: tokens)
        let result = makeResult(segments: [seg], windowStartAbsMs: 0)

        // Large margin so everything is speculative
        let state = stabilizer.update(decodeResult: result, windowEndAbsMs: 800, commitMarginMs: 1000)

        // Speculative should have proper spacing
        XCTAssertEqual(state.rawSpeculative, "Hello there friend")
    }
}
