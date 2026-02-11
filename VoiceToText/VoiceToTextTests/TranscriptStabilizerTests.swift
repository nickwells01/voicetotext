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

    /// Helper: build a DecodeResult from segment text (tokens are provided but not used by LA-2 commit logic)
    private func makeSimpleResult(_ text: String, windowStartAbsMs: Int = 0) -> DecodeResult {
        let seg = makeSegment(text, startMs: 0, endMs: 1000, tokens: [])
        return makeResult(segments: [seg], windowStartAbsMs: windowStartAbsMs)
    }

    // MARK: - LocalAgreement-2 Core

    func testFirstDecodeIsAllSpeculative() {
        let stabilizer = TranscriptStabilizer()

        let result = makeSimpleResult("Hello world this is a test")
        let state = stabilizer.update(decodeResult: result, windowEndAbsMs: 1000, commitMarginMs: 300)

        // First decode: nothing to agree with, so everything is speculative
        XCTAssertTrue(state.rawCommitted.isEmpty)
        XCTAssertEqual(state.rawSpeculative, "Hello world this is a test")
    }

    func testTwoAgreingDecodesCommitPrefix() {
        let stabilizer = TranscriptStabilizer()

        // First decode
        let res1 = makeSimpleResult("Hello world this is")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        // Second decode agrees on "Hello world" but diverges after
        let res2 = makeSimpleResult("Hello world something else")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        // "Hello world" agreed upon by both decodes → committed
        XCTAssertTrue(state.rawCommitted.contains("Hello"))
        XCTAssertTrue(state.rawCommitted.contains("world"))
        // Divergent part should be speculative
        XCTAssertTrue(state.rawSpeculative.contains("something"))
    }

    func testFullAgreementCommitsAll() {
        let stabilizer = TranscriptStabilizer()

        // Two identical decodes
        let res1 = makeSimpleResult("Hello world")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeSimpleResult("Hello world")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        XCTAssertEqual(state.rawCommitted, "Hello world")
        XCTAssertTrue(state.rawSpeculative.isEmpty)
    }

    func testCommittedWordCountAdvancesMonotonically() {
        let stabilizer = TranscriptStabilizer()

        let res1 = makeSimpleResult("Hello world foo bar")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeSimpleResult("Hello world foo baz")
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)
        XCTAssertEqual(stabilizer.state.committedWordCount, 3) // "Hello world foo"

        // Third decode diverges earlier — committedWordCount should not go backwards
        let res3 = makeSimpleResult("Hello world something different")
        stabilizer.update(decodeResult: res3, windowEndAbsMs: 1500, commitMarginMs: 300)
        XCTAssertGreaterThanOrEqual(stabilizer.state.committedWordCount, 3)
    }

    // MARK: - Speculative Replacement

    func testSpeculativeTailIsReplacedNotAppended() {
        let stabilizer = TranscriptStabilizer()

        // First decode
        let res1 = makeSimpleResult("Hello speculative")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 500, commitMarginMs: 300)

        // Second decode with different speculative tail (only "Hello" agrees)
        let res2 = makeSimpleResult("Hello actual words")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 750, commitMarginMs: 300)

        // "speculative" should be gone from speculative text
        XCTAssertFalse(state.rawSpeculative.contains("speculative"))
    }

    // MARK: - No Duplicates

    func testNoDuplicatesAcrossDecodes() {
        let stabilizer = TranscriptStabilizer()

        // First decode
        let res1 = makeSimpleResult("Hello world foo")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 500)

        // Second decode with overlapping words
        let res2 = makeSimpleResult("Hello world foo bar")
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 500)

        // Third decode
        let res3 = makeSimpleResult("Hello world foo bar baz")
        let state = stabilizer.update(decodeResult: res3, windowEndAbsMs: 1500, commitMarginMs: 500)

        // "world" should only appear once in full text
        let fullText = state.fullRawText
        let worldCount = fullText.components(separatedBy: "world").count - 1
        XCTAssertEqual(worldCount, 1, "word 'world' should appear exactly once")
    }

    // MARK: - Finalize Commits Everything

    func testFinalizeAllCommitsEverything() {
        let stabilizer = TranscriptStabilizer()

        // Single decode — everything is speculative
        let result = makeSimpleResult("Hello world")
        stabilizer.update(decodeResult: result, windowEndAbsMs: 500, commitMarginMs: 1000)
        XCTAssertFalse(stabilizer.state.rawSpeculative.isEmpty)

        // Finalize
        let state = stabilizer.finalizeAll()
        XCTAssertTrue(state.rawSpeculative.isEmpty)
        XCTAssertFalse(state.rawCommitted.isEmpty)
        XCTAssertTrue(state.rawCommitted.contains("Hello"))
        XCTAssertTrue(state.rawCommitted.contains("world"))
    }

    // MARK: - Committed Text Never Shrinks

    func testCommittedTextNeverShrinks() {
        let stabilizer = TranscriptStabilizer()

        // Build up committed text with two agreeing decodes
        let res1 = makeSimpleResult("Hello world this is great")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        let res2 = makeSimpleResult("Hello world this is great")
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        let committedAfter = stabilizer.state.rawCommitted
        XCTAssertFalse(committedAfter.isEmpty)

        // Third decode with completely different text
        let res3 = makeSimpleResult("Something entirely different")
        stabilizer.update(decodeResult: res3, windowEndAbsMs: 1500, commitMarginMs: 300)

        // Committed should not have shrunk (no common prefix means no new commits,
        // but existing committed text stays)
        XCTAssertGreaterThanOrEqual(stabilizer.state.rawCommitted.count, committedAfter.count)
    }

    // MARK: - Whitespace Normalization

    func testWhitespaceNormalization() {
        let stabilizer = TranscriptStabilizer()

        // Two agreeing decodes with messy whitespace in segment text
        let seg1 = makeSegment("  Hello   world  ", startMs: 0, endMs: 400, tokens: [])
        let res1 = makeResult(segments: [seg1], windowStartAbsMs: 0)
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 0)

        let seg2 = makeSegment("  Hello   world  ", startMs: 0, endMs: 400, tokens: [])
        let res2 = makeResult(segments: [seg2], windowStartAbsMs: 0)
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 0)

        // No double spaces
        XCTAssertFalse(state.rawCommitted.contains("  "))
        // No leading/trailing whitespace
        XCTAssertEqual(state.rawCommitted, state.rawCommitted.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Reset

    func testReset() {
        let stabilizer = TranscriptStabilizer()

        // Two decodes to get committed text
        let res1 = makeSimpleResult("Hello world")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 0)
        let res2 = makeSimpleResult("Hello world")
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 0)

        XCTAssertFalse(stabilizer.state.rawCommitted.isEmpty)

        stabilizer.reset()

        XCTAssertTrue(stabilizer.state.rawCommitted.isEmpty)
        XCTAssertTrue(stabilizer.state.rawSpeculative.isEmpty)
        XCTAssertEqual(stabilizer.state.committedWordCount, 0)
        XCTAssertTrue(stabilizer.state.previousDecodeRawWords.isEmpty)
    }

    // MARK: - Punctuation-Insensitive Agreement

    func testPunctuationDoesNotBreakAgreement() {
        let stabilizer = TranscriptStabilizer()

        // First decode without trailing period
        let res1 = makeSimpleResult("Hello world")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        // Second decode with trailing period — "world" vs "world." should agree after normalization
        let res2 = makeSimpleResult("Hello world.")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        XCTAssertTrue(state.rawCommitted.contains("Hello"))
        XCTAssertTrue(state.rawCommitted.contains("world"))
    }

    // MARK: - Case-Insensitive Agreement

    func testCaseDoesNotBreakAgreement() {
        let stabilizer = TranscriptStabilizer()

        let res1 = makeSimpleResult("The Quick Brown Fox")
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 300)

        // Second decode with different casing
        let res2 = makeSimpleResult("The quick brown Fox jumps")
        let state = stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 300)

        // All four words should agree (case-insensitive normalization)
        XCTAssertTrue(state.rawCommitted.lowercased().contains("the quick brown fox"))
    }

    // MARK: - Speculative Spacing

    func testSpeculativeTokenSpacingPreserved() {
        let stabilizer = TranscriptStabilizer()

        let result = makeSimpleResult("Hello there friend")

        // Single decode: everything speculative
        let state = stabilizer.update(decodeResult: result, windowEndAbsMs: 800, commitMarginMs: 1000)

        // Speculative should have proper spacing
        XCTAssertEqual(state.rawSpeculative, "Hello there friend")
    }
}
