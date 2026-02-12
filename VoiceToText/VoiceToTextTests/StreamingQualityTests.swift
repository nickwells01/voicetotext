import XCTest
@testable import VoiceToText

/// Integration tests for streaming quality metrics.
/// These tests require the Whisper model to be available on disk.
@MainActor
final class StreamingQualityTests: XCTestCase {

    // MARK: - Constants

    private static let shortPhrase = "The quick brown fox jumps over the lazy dog. She sells seashells by the seashore."

    private static let longPhrase = "The quick brown fox jumps over the lazy dog. She sells seashells by the seashore. Peter Piper picked a peck of pickled peppers. How much wood would a woodchuck chuck if a woodchuck could chuck wood. The rain in Spain stays mainly in the plain."

    // MARK: - Helpers

    private func loadModelIfNeeded(_ whisperManager: WhisperManager) async throws {
        let modelPath = NSHomeDirectory() + "/Library/Application Support/VoiceToText/Models/ggml-base.en-q5_1.bin"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelPath), "Whisper model not found")
        let modelURL = URL(fileURLWithPath: modelPath)
        try await whisperManager.loadModel(url: modelURL, language: .english)
    }

    /// Compute the time-to-first-word in milliseconds from tick metrics.
    private func timeToFirstWord(from metrics: [TickMetrics]) -> Int {
        let firstWordTick = metrics.first { !$0.committed.isEmpty && !$0.isSilent }
        return firstWordTick?.audioPositionMs ?? Int.max
    }

    /// Compute p95 decode latency from tick metrics (excluding silent ticks).
    private func p95Latency(from metrics: [TickMetrics]) -> Double {
        let latencies = metrics
            .filter { !$0.isSilent }
            .map(\.decodeLatencyMs)
            .sorted()
        guard !latencies.isEmpty else { return 0 }
        let index = Int(floor(Double(latencies.count) * 0.95))
        return latencies[min(index, latencies.count - 1)]
    }

    /// Compute committed word stability: fraction of ever-committed words that survive
    /// to the final committed text.
    private func commitStability(from metrics: [TickMetrics]) -> Double {
        // Collect all unique words ever seen in committed text across ticks
        var everCommittedWords: Set<String> = []
        for tick in metrics {
            let words = tick.committed
                .lowercased()
                .split(separator: " ", omittingEmptySubsequences: true)
                .map { String($0) }
            for word in words {
                everCommittedWords.insert(word)
            }
        }

        guard !everCommittedWords.isEmpty else { return 1.0 }

        // Get final committed words
        let finalCommitted = metrics.last?.committed ?? ""
        let finalWords = Set(
            finalCommitted
                .lowercased()
                .split(separator: " ", omittingEmptySubsequences: true)
                .map { String($0) }
        )

        let survivingCount = everCommittedWords.intersection(finalWords).count
        return Double(survivingCount) / Double(everCommittedWords.count)
    }

    private func runShortBenchmark() async throws -> TestHarnessReport {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        var config = TestHarnessConfig()
        config.phrase = Self.shortPhrase

        let harness = TranscriptionTestHarness()
        return try await harness.run(config: config, whisperManager: whisperManager)
    }

    private func runLongBenchmark() async throws -> TestHarnessReport {
        let whisperManager = WhisperManager()
        try await loadModelIfNeeded(whisperManager)

        var config = TestHarnessConfig()
        config.phrase = Self.longPhrase

        let harness = TranscriptionTestHarness()
        return try await harness.run(config: config, whisperManager: whisperManager)
    }

    // MARK: - Flicker Rate Tests

    func testFlickerRateShortSpeech() async throws {
        let report = try await runShortBenchmark()

        XCTAssertLessThan(
            report.flickerEvents.count,
            5,
            "Short speech flicker events (\(report.flickerEvents.count)) should be < 5"
        )
    }

    func testFlickerRateLongSpeech() async throws {
        let report = try await runLongBenchmark()

        XCTAssertLessThan(
            report.flickerEvents.count,
            20,
            "Long speech flicker events (\(report.flickerEvents.count)) should be < 20"
        )
    }

    // MARK: - Time to First Word Tests

    func testTimeToFirstWordShort() async throws {
        let report = try await runShortBenchmark()
        let ttfw = timeToFirstWord(from: report.tickMetrics)

        XCTAssertLessThan(
            ttfw,
            1500,
            "Short speech TTFW (\(ttfw)ms) should be < 1500ms"
        )
    }

    func testTimeToFirstWordLong() async throws {
        let report = try await runLongBenchmark()
        let ttfw = timeToFirstWord(from: report.tickMetrics)

        XCTAssertLessThan(
            ttfw,
            1500,
            "Long speech TTFW (\(ttfw)ms) should be < 1500ms"
        )
    }

    // MARK: - Decode Latency Tests

    func testDecodeLatencyP95Short() async throws {
        let report = try await runShortBenchmark()
        let p95 = p95Latency(from: report.tickMetrics)

        XCTAssertLessThan(
            p95,
            300.0,
            "Short speech p95 decode latency (\(String(format: "%.0f", p95))ms) should be < 300ms"
        )
    }

    func testDecodeLatencyP95Long() async throws {
        let report = try await runLongBenchmark()
        let p95 = p95Latency(from: report.tickMetrics)

        XCTAssertLessThan(
            p95,
            800.0,
            "Long speech p95 decode latency (\(String(format: "%.0f", p95))ms) should be < 800ms"
        )
    }

    // MARK: - Commit Stability Tests

    func testCommitStabilityShort() async throws {
        let report = try await runShortBenchmark()
        let stability = commitStability(from: report.tickMetrics)

        XCTAssertGreaterThan(
            stability,
            0.95,
            "Short speech commit stability (\(String(format: "%.1f", stability * 100))%) should be > 95%"
        )
    }

    func testCommitStabilityLong() async throws {
        let report = try await runLongBenchmark()
        let stability = commitStability(from: report.tickMetrics)

        XCTAssertGreaterThan(
            stability,
            0.90,
            "Long speech commit stability (\(String(format: "%.1f", stability * 100))%) should be > 90%"
        )
    }
}
