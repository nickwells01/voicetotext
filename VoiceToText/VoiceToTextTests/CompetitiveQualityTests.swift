import XCTest
@testable import VoiceToText

/// Integration tests that validate market-competitive quality thresholds.
/// These require the Whisper model to be installed on disk.
@MainActor
final class CompetitiveQualityTests: XCTestCase {

    // MARK: - Test Phrases

    private static let shortPhrase = "The quick brown fox jumps over the lazy dog. She sells seashells by the seashore."

    private static let longPhrase = "The quick brown fox jumps over the lazy dog. She sells seashells by the seashore. Peter Piper picked a peck of pickled peppers. How much wood would a woodchuck chuck if a woodchuck could chuck wood. The rain in Spain stays mainly in the plain."

    private static let dictationParagraph = """
    The history of computing is a fascinating journey. Charles Babbage conceptualized the first mechanical \
    computer in the early nineteenth century. Ada Lovelace, who worked with Babbage, wrote what is considered \
    the first algorithm. Electronic computers emerged during World War Two. The ENIAC, completed in 1945, \
    was one of the first general purpose electronic computers. Since then, transistors replaced vacuum tubes, \
    and microprocessors enabled personal computers. Today we carry more computing power in our pockets than \
    existed decades ago. The internet transformed communication, commerce, and entertainment. Cloud computing \
    now allows businesses of all sizes to access powerful infrastructure on demand.
    """

    private static let punctuatedPhrase = "Is this working? Yes, it is! The quick brown fox, which was quite agile, jumped over the lazy dog. Meanwhile, the cat sat quietly."

    private static let technicalPhrase = "The API endpoint uses JSON format to communicate with the macOS application. We need to update the SwiftUI views and ensure the OAuth tokens are refreshed properly."

    // MARK: - Helpers

    private func loadModelIfNeeded(_ whisperManager: WhisperManager) async throws {
        let modelPath = NSHomeDirectory() + "/Library/Application Support/VoiceToText/Models/ggml-base.en-q5_1.bin"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelPath), "Whisper model not found")
        let modelURL = URL(fileURLWithPath: modelPath)
        try await whisperManager.loadModel(url: modelURL, language: .english)
    }

    private func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = reference.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0) }
        let hyp = hypothesis.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0) }
        guard !ref.isEmpty else { return hyp.isEmpty ? 0.0 : 1.0 }

        var dp = Array(0...hyp.count)
        for i in 1...ref.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...hyp.count {
                let temp = dp[j]
                if ref[i - 1] == hyp[j - 1] {
                    dp[j] = prev
                } else {
                    dp[j] = min(prev, dp[j], dp[j - 1]) + 1
                }
                prev = temp
            }
        }
        return Double(dp[hyp.count]) / Double(ref.count)
    }

    private func runHarness(phrase: String, voiceRate: Float = 180, whisperManager: WhisperManager) async throws -> TestHarnessReport {
        var config = TestHarnessConfig()
        config.phrase = phrase
        config.voiceRate = voiceRate
        let harness = TranscriptionTestHarness()
        return try await harness.run(config: config, whisperManager: whisperManager)
    }

    private func extractLatencies(from report: TestHarnessReport) -> [Double] {
        report.tickMetrics.filter { !$0.isSilent }.map(\.decodeLatencyMs)
    }

    // MARK: - Final Output Quality

    func testFinalOutputWERUnderFivePercent() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.shortPhrase, whisperManager: whisperManager)
        let wer = wordErrorRate(reference: Self.shortPhrase, hypothesis: report.fullDecodeResult)

        XCTAssertLessThan(wer, 0.05,
            "Full-decode WER \(String(format: "%.1f%%", wer * 100)) exceeds 5% market leader threshold")
    }

    func testFinalOutputWERLongUnderFivePercent() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.longPhrase, whisperManager: whisperManager)
        let wer = wordErrorRate(reference: Self.longPhrase, hypothesis: report.fullDecodeResult)

        XCTAssertLessThan(wer, 0.05,
            "Full-decode WER \(String(format: "%.1f%%", wer * 100)) exceeds 5% for long audio")
    }

    func testFinalOutputPreservesAllSentences() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.shortPhrase, whisperManager: whisperManager)
        let output = report.fullDecodeResult.lowercased()

        // Every sentence-ending word from the reference should appear in the output
        let sentences = Self.shortPhrase.components(separatedBy: ". ")
        for sentence in sentences where !sentence.isEmpty {
            let lastWord = sentence.split(separator: " ").last.map(String.init) ?? ""
            let cleaned = lastWord.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard !cleaned.isEmpty else { continue }

            XCTAssertTrue(output.contains(cleaned),
                "Sentence-ending word '\(cleaned)' missing from full-decode output")
        }
    }

    func testFullDecodeWERBetterThanOrEqualToStreaming() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.shortPhrase, whisperManager: whisperManager)
        let streamingWER = wordErrorRate(reference: Self.shortPhrase, hypothesis: report.streamingResult)
        let fullWER = wordErrorRate(reference: Self.shortPhrase, hypothesis: report.fullDecodeResult)

        // Full decode should be at least as good as streaming (lower or equal WER).
        // This is expected because full decode has the complete audio context.
        XCTAssertLessThanOrEqual(fullWER, streamingWER + 0.01,
            "Full-decode WER (\(String(format: "%.1f%%", fullWER * 100))) should be <= streaming WER (\(String(format: "%.1f%%", streamingWER * 100)))")
    }

    // MARK: - Latency Competitiveness

    func testP99DecodeLatencyUnder1Second() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.shortPhrase, whisperManager: whisperManager)
        let latencies = extractLatencies(from: report).sorted()

        guard !latencies.isEmpty else {
            XCTFail("No decode ticks recorded")
            return
        }

        let p99Index = Int(Double(latencies.count - 1) * 0.99)
        let p99 = latencies[p99Index]

        XCTAssertLessThan(p99, 1000,
            "P99 decode latency \(String(format: "%.0f", p99))ms exceeds 1000ms market minimum")
    }

    func testAverageLatencyUnder500ms() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.longPhrase, whisperManager: whisperManager)
        let latencies = extractLatencies(from: report)

        guard !latencies.isEmpty else {
            XCTFail("No decode ticks recorded")
            return
        }

        let avg = latencies.reduce(0, +) / Double(latencies.count)

        XCTAssertLessThan(avg, 500,
            "Average decode latency \(String(format: "%.0f", avg))ms exceeds 500ms target")
    }

    func testNoDecodeExceeds3Seconds() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.shortPhrase, whisperManager: whisperManager)
        let latencies = extractLatencies(from: report)

        let overThreshold = latencies.filter { $0 > 3000 }
        XCTAssertTrue(overThreshold.isEmpty,
            "\(overThreshold.count) decode(s) exceeded 3s — likely hallucination stall")
    }

    // MARK: - Robustness

    func testVaryingSpeechRates() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        // Slow speech (140 WPM)
        let slowReport = try await runHarness(
            phrase: Self.shortPhrase, voiceRate: 140, whisperManager: whisperManager)
        let slowWER = wordErrorRate(reference: Self.shortPhrase, hypothesis: slowReport.fullDecodeResult)

        XCTAssertLessThan(slowWER, 0.08,
            "Slow speech (140 WPM) full-decode WER \(String(format: "%.1f%%", slowWER * 100)) exceeds 8%")

        // Fast speech (220 WPM)
        let fastReport = try await runHarness(
            phrase: Self.shortPhrase, voiceRate: 220, whisperManager: whisperManager)
        let fastWER = wordErrorRate(reference: Self.shortPhrase, hypothesis: fastReport.fullDecodeResult)

        XCTAssertLessThan(fastWER, 0.08,
            "Fast speech (220 WPM) full-decode WER \(String(format: "%.1f%%", fastWER * 100)) exceeds 8%")
    }

    func testLongFormDictation() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.dictationParagraph, whisperManager: whisperManager)
        let wer = wordErrorRate(reference: Self.dictationParagraph, hypothesis: report.fullDecodeResult)

        XCTAssertLessThan(wer, 0.05,
            "Long-form dictation WER \(String(format: "%.1f%%", wer * 100)) exceeds 5%")
    }

    func testPunctuatedSpeech() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.punctuatedPhrase, whisperManager: whisperManager)
        let output = report.fullDecodeResult

        // Verify punctuation is present in the output
        XCTAssertTrue(output.contains("?"), "Question mark missing from punctuated speech output")
        XCTAssertTrue(output.contains("."), "Period missing from punctuated speech output")
    }

    func testTechnicalVocabulary() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let report = try await runHarness(phrase: Self.technicalPhrase, whisperManager: whisperManager)
        let output = report.fullDecodeResult.lowercased()

        // Technical terms that should survive transcription
        let expectedTerms = ["api", "json", "macos"]
        for term in expectedTerms {
            XCTAssertTrue(output.contains(term),
                "Technical term '\(term)' missing from transcription output")
        }
    }
}
