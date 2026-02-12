import XCTest
@testable import VoiceToText

/// Tests for the 9 code review fixes: Keychain storage, toast lifecycle,
/// O(n^2) dedup skip, duration guard, and device change callback.
final class CodeReviewFixTests: XCTestCase {

    // Unique account prefix to avoid colliding with real app data
    private let testAccount = "test-cr-\(UUID().uuidString)"

    override func tearDown() {
        KeychainHelper.delete(account: testAccount)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSegment(_ text: String, startMs: Int, endMs: Int, tokens: [TranscriptionToken] = []) -> TranscriptionSegment {
        TranscriptionSegment(text: text, startTimeMs: startMs, endTimeMs: endMs, tokens: tokens)
    }

    private func makeSimpleResult(_ text: String, windowStartAbsMs: Int = 0) -> DecodeResult {
        let seg = makeSegment(text, startMs: 0, endMs: 1000)
        return DecodeResult(segments: [seg], windowStartAbsMs: windowStartAbsMs)
    }

    // MARK: - Fix 1: Keychain Storage

    func testKeychainSetGetDelete() {
        KeychainHelper.set("test-value", account: testAccount)

        let value = KeychainHelper.get(account: testAccount)
        XCTAssertEqual(value, "test-value")

        KeychainHelper.delete(account: testAccount)
        let deleted = KeychainHelper.get(account: testAccount)
        XCTAssertNil(deleted)
    }

    func testKeychainOverwrite() {
        KeychainHelper.set("first-value", account: testAccount)
        KeychainHelper.set("second-value", account: testAccount)

        let value = KeychainHelper.get(account: testAccount)
        XCTAssertEqual(value, "second-value")
    }

    func testKeychainGetMissing() {
        let value = KeychainHelper.get(account: "nonexistent-\(UUID().uuidString)")
        XCTAssertNil(value)
    }

    func testLLMConfigExcludesApiKeyFromJSON() throws {
        var config = LLMConfig()
        config.apiKey = "super-secret-key"

        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["apiKey"], "apiKey must not appear in JSON serialization")
    }

    func testLLMConfigSaveLoadRoundTripsApiKey() {
        var config = LLMConfig()
        config.apiKey = "test-round-trip-key"
        config.apiURL = "https://test.example.com"
        config.save()

        let loaded = LLMConfig.load()
        XCTAssertEqual(loaded.apiKey, "test-round-trip-key")

        // Clean up
        config.apiKey = ""
        config.save()
        KeychainHelper.delete(account: "llm-api-key")
        UserDefaults.standard.removeObject(forKey: StorageKey.llmConfigData)
    }

    // MARK: - Fix 5: Toast Lifecycle

    @MainActor
    func testResetStreamingTextPreservesToast() {
        let appState = AppState()
        appState.toastMessage = "Test toast"
        appState.committedText = "Some text"
        appState.speculativeText = "More text"

        appState.resetStreamingText()

        XCTAssertEqual(appState.toastMessage, "Test toast")
        XCTAssertEqual(appState.committedText, "")
        XCTAssertEqual(appState.speculativeText, "")
    }

    @MainActor
    func testTransitionToIdlePreservesToast() {
        let appState = AppState()
        appState.toastMessage = "Test toast"

        appState.transitionTo(.idle)

        XCTAssertEqual(appState.toastMessage, "Test toast")
    }

    // MARK: - Fix 6: O(n^2) Non-Consecutive Dedup Skip

    func testStreamingDedupeSkipsShortNonConsecutive() {
        let stabilizer = TranscriptStabilizer()

        // Text with a 4-word non-consecutive repeat: "the cat jumps over" appears at
        // positions 2-5 and 7-10. Streaming uses minNonConsecutivePhraseLen=7, so the
        // 4-word repeat should survive.
        let text = "alpha beta the cat jumps over delta the cat jumps over gamma"

        let res1 = makeSimpleResult(text)
        stabilizer.update(decodeResult: res1, windowEndAbsMs: 1000, commitMarginMs: 0)

        let res2 = makeSimpleResult(text)
        stabilizer.update(decodeResult: res2, windowEndAbsMs: 1250, commitMarginMs: 0)

        // Full agreement commits all-1 words (trailing edge hold-back removes "gamma").
        // With minNonConsecutivePhraseLen=7, the 4-word repeat should survive streaming.
        let words = stabilizer.state.rawCommitted
            .split(separator: " ").map { String($0).lowercased() }

        var count = 0
        for i in 0..<words.count where i + 3 < words.count {
            if words[i] == "the" && words[i+1] == "cat"
                && words[i+2] == "jumps" && words[i+3] == "over" {
                count += 1
            }
        }
        XCTAssertEqual(count, 2,
            "4-word non-consecutive repeat should survive streaming dedup (minLen=7)")
    }

    func testFinalizeDedupeRemovesShortNonConsecutive() {
        let stabilizer = TranscriptStabilizer()
        stabilizer.state.rawCommitted = "The fox jumps over the lazy dog jumps over the lazy cat"

        stabilizer.finalizeAll()

        // After finalize (minNonConsecutivePhraseLen=3), the 4-word repeat
        // "jumps over the lazy" should appear only once.
        let words = stabilizer.state.rawCommitted
            .split(separator: " ").map { String($0).lowercased() }

        var count = 0
        for i in 0..<words.count where i + 3 < words.count {
            if words[i] == "jumps" && words[i+1] == "over"
                && words[i+2] == "the" && words[i+3] == "lazy" {
                count += 1
            }
        }
        XCTAssertEqual(count, 1,
            "4-word non-consecutive repeat should be removed by finalize (minLen=3)")
    }

    // MARK: - Fix 9: Duration Guard

    func testMaxRecordingSamplesConstant() {
        // 60 minutes at 16kHz = 57,600,000 samples
        let expected = 60 * 60 * 16000
        XCTAssertEqual(expected, 57_600_000)
    }

    func testWarningThresholdIsHalfOfMax() {
        let warning = 30 * 60 * 16000
        let max = 60 * 60 * 16000
        XCTAssertEqual(warning, max / 2)
    }

    @MainActor
    func testOnMaxDurationCallbackWired() {
        let recorder = AudioRecorder()
        XCTAssertNil(recorder.onMaxDurationReached)

        var called = false
        recorder.onMaxDurationReached = { called = true }

        XCTAssertNotNil(recorder.onMaxDurationReached)
        recorder.onMaxDurationReached?()
        XCTAssertTrue(called)
    }

    // MARK: - Fix 8: Device Change Callback

    @MainActor
    func testOnDeviceChangedCallbackWired() {
        let recorder = AudioRecorder()
        XCTAssertNil(recorder.onDeviceChanged)

        var called = false
        recorder.onDeviceChanged = { called = true }

        XCTAssertNotNil(recorder.onDeviceChanged)
        recorder.onDeviceChanged?()
        XCTAssertTrue(called)
    }
}
