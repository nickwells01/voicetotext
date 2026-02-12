import XCTest
@testable import VoiceToText

/// Integration tests that compare test harness results against stored baselines.
/// These tests require the Whisper model to be available on disk.
@MainActor
final class RegressionGuardTests: XCTestCase {

    // MARK: - Baseline Model

    private struct QualityBaseline: Codable {
        let model: String
        let streaming_wer: Double
        let full_wer: Double
        let flicker_count: Int
        let avg_latency_ms: Double
        let ttfw_ms: Int
    }

    // MARK: - Constants

    private static let shortPhrase = "The quick brown fox jumps over the lazy dog. She sells seashells by the seashore."

    private static let longPhrase = "The quick brown fox jumps over the lazy dog. She sells seashells by the seashore. Peter Piper picked a peck of pickled peppers. How much wood would a woodchuck chuck if a woodchuck could chuck wood. The rain in Spain stays mainly in the plain."

    // MARK: - Tolerances

    private static let werTolerance = 0.02
    private static let flickerTolerance = 0.50
    private static let latencyTolerance = 0.30
    private static let ttfwToleranceMs = 500.0

    // MARK: - Helpers

    private func loadBaselines() throws -> [String: QualityBaseline] {
        let testDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = testDir.appendingPathComponent("Baselines/quality_baselines.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: QualityBaseline].self, from: data)
    }

    private func loadModelIfNeeded(_ whisperManager: WhisperManager) async throws {
        let modelPath = NSHomeDirectory() + "/Library/Application Support/VoiceToText/Models/ggml-base.en-q5_1.bin"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelPath), "Whisper model not found")
        let modelURL = URL(fileURLWithPath: modelPath)
        try await whisperManager.loadModel(url: modelURL, language: .english)
    }

    /// Compute word error rate using Levenshtein distance on word arrays.
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

    /// Extract summary metrics from a TestHarnessReport.
    private func extractMetrics(from report: TestHarnessReport) -> (
        streamingWER: Double,
        fullWER: Double,
        flickerCount: Int,
        avgLatencyMs: Double,
        ttfwMs: Int
    ) {
        let streamingWER = wordErrorRate(reference: report.referenceText, hypothesis: report.streamingResult)
        let fullWER = wordErrorRate(reference: report.referenceText, hypothesis: report.fullDecodeResult)

        let decodeTicks = report.tickMetrics.filter { !$0.isSilent }
        let avgLatency = decodeTicks.isEmpty ? 0 :
            decodeTicks.map(\.decodeLatencyMs).reduce(0, +) / Double(decodeTicks.count)

        let firstWordTick = report.tickMetrics.first { !$0.committed.isEmpty && !$0.isSilent }
        let ttfw = firstWordTick?.audioPositionMs ?? 0

        return (streamingWER, fullWER, report.flickerEvents.count, avgLatency, ttfw)
    }

    // MARK: - Regression Tests

    func testShortTTSRegression() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let baselines = try loadBaselines()
        let baseline = try XCTUnwrap(baselines["short_tts"], "Missing 'short_tts' baseline")

        var config = TestHarnessConfig()
        config.phrase = Self.shortPhrase

        let harness = TranscriptionTestHarness()
        let report = try await harness.run(config: config, whisperManager: whisperManager)
        let metrics = extractMetrics(from: report)

        XCTAssertLessThanOrEqual(
            metrics.streamingWER,
            baseline.streaming_wer + Self.werTolerance,
            "Streaming WER \(String(format: "%.3f", metrics.streamingWER)) exceeds baseline \(baseline.streaming_wer) + tolerance \(Self.werTolerance)"
        )
        XCTAssertLessThanOrEqual(
            metrics.fullWER,
            baseline.full_wer + Self.werTolerance,
            "Full WER \(String(format: "%.3f", metrics.fullWER)) exceeds baseline \(baseline.full_wer) + tolerance \(Self.werTolerance)"
        )
        XCTAssertLessThanOrEqual(
            metrics.flickerCount,
            Int(ceil(Double(baseline.flicker_count) * (1.0 + Self.flickerTolerance))),
            "Flicker count \(metrics.flickerCount) exceeds baseline \(baseline.flicker_count) + 50%"
        )
        XCTAssertLessThanOrEqual(
            metrics.avgLatencyMs,
            baseline.avg_latency_ms * (1.0 + Self.latencyTolerance),
            "Avg latency \(String(format: "%.0f", metrics.avgLatencyMs))ms exceeds baseline \(baseline.avg_latency_ms)ms + 30%"
        )
        XCTAssertLessThanOrEqual(
            Double(metrics.ttfwMs),
            Double(baseline.ttfw_ms) + Self.ttfwToleranceMs,
            "TTFW \(metrics.ttfwMs)ms exceeds baseline \(baseline.ttfw_ms)ms + \(Int(Self.ttfwToleranceMs))ms"
        )
    }

    func testLongTTSRegression() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        let baselines = try loadBaselines()
        let baseline = try XCTUnwrap(baselines["long_tts"], "Missing 'long_tts' baseline")

        var config = TestHarnessConfig()
        config.phrase = Self.longPhrase

        let harness = TranscriptionTestHarness()
        let report = try await harness.run(config: config, whisperManager: whisperManager)
        let metrics = extractMetrics(from: report)

        XCTAssertLessThanOrEqual(
            metrics.streamingWER,
            baseline.streaming_wer + Self.werTolerance,
            "Streaming WER \(String(format: "%.3f", metrics.streamingWER)) exceeds baseline \(baseline.streaming_wer) + tolerance \(Self.werTolerance)"
        )
        XCTAssertLessThanOrEqual(
            metrics.fullWER,
            baseline.full_wer + Self.werTolerance,
            "Full WER \(String(format: "%.3f", metrics.fullWER)) exceeds baseline \(baseline.full_wer) + tolerance \(Self.werTolerance)"
        )
        XCTAssertLessThanOrEqual(
            metrics.flickerCount,
            Int(ceil(Double(baseline.flicker_count) * (1.0 + Self.flickerTolerance))),
            "Flicker count \(metrics.flickerCount) exceeds baseline \(baseline.flicker_count) + 50%"
        )
        XCTAssertLessThanOrEqual(
            metrics.avgLatencyMs,
            baseline.avg_latency_ms * (1.0 + Self.latencyTolerance),
            "Avg latency \(String(format: "%.0f", metrics.avgLatencyMs))ms exceeds baseline \(baseline.avg_latency_ms)ms + 30%"
        )
        XCTAssertLessThanOrEqual(
            Double(metrics.ttfwMs),
            Double(baseline.ttfw_ms) + Self.ttfwToleranceMs,
            "TTFW \(metrics.ttfwMs)ms exceeds baseline \(baseline.ttfw_ms)ms + \(Int(Self.ttfwToleranceMs))ms"
        )
    }

    // MARK: - Invariant Tests

    func testCommittedTextNeverShrinks() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        var config = TestHarnessConfig()
        config.phrase = Self.shortPhrase

        let harness = TranscriptionTestHarness()
        let report = try await harness.run(config: config, whisperManager: whisperManager)

        var previousLength = 0
        for tick in report.tickMetrics {
            let currentLength = tick.committed.count
            XCTAssertGreaterThanOrEqual(
                currentLength,
                previousLength,
                "Committed text shrank from \(previousLength) to \(currentLength) chars at tick \(tick.index)"
            )
            previousLength = currentLength
        }
    }

    func testNoHallucinationInShortSpeech() async throws {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        var config = TestHarnessConfig()
        config.phrase = Self.shortPhrase

        let harness = TranscriptionTestHarness()
        let report = try await harness.run(config: config, whisperManager: whisperManager)

        // Check for 3+ word phrases repeated consecutively in the streaming result
        let words = report.streamingResult
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0).lowercased() }

        let phraseLength = 3
        guard words.count >= phraseLength * 2 else { return }

        for i in 0...(words.count - phraseLength * 2) {
            let phrase = Array(words[i..<(i + phraseLength)])
            let nextPhrase = Array(words[(i + phraseLength)..<(i + phraseLength * 2)])
            XCTAssertNotEqual(
                phrase,
                nextPhrase,
                "Hallucination detected: '\(phrase.joined(separator: " "))' repeated consecutively at word index \(i)"
            )
        }
    }
}
