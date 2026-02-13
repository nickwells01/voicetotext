import Foundation
import AVFoundation
import AppKit
import os

// MARK: - Test Harness Config

struct TestHarnessConfig {
    var phrase: String = "The quick brown fox jumps over the lazy dog. She sells seashells by the seashore."
    var voiceRate: Float = 180  // words per minute
    var simulateRealTime: Bool = false
    var pipelineConfig: PipelineConfig = PipelineConfig()
    var skipWarmup: Bool = false
}

// MARK: - Tick Metrics

struct TickMetrics {
    let index: Int
    let audioPositionMs: Int
    let decodeLatencyMs: Double
    let committed: String
    let speculative: String
    let previousSpeculative: String
    let isSilent: Bool
}

// MARK: - Test Harness Report

struct TestHarnessReport {
    let tickMetrics: [TickMetrics]
    let streamingResult: String
    let fullDecodeResult: String
    let productionResult: String  // full decode after finalizeAll() post-processing
    let referenceText: String
    let audioDurationMs: Int
    let totalElapsedMs: Double
    let flickerEvents: [Int]  // tick indices where flicker occurred
}

// MARK: - Test Phrase

struct TestPhrase {
    let id: String
    let category: String
    let text: String
    let expectedDurationRange: ClosedRange<Int>  // seconds, approximate
}

// MARK: - Batch Results

struct PhraseResult {
    let phrase: TestPhrase
    let streamingWER: Double
    let fullDecodeWER: Double
    let productionWER: Double  // WER after finalizeAll() post-processing
    let flickerCount: Int
    let timeToFirstWordMs: Int
    let audioDurationMs: Int
    let passed: Bool
}

struct BatchReport {
    let results: [PhraseResult]
    let meanStreamingWER: Double
    let meanFullDecodeWER: Double
    let meanProductionWER: Double
    let maxFullDecodeWER: Double
    let maxProductionWER: Double
    let passCount: Int
    let failCount: Int
}

// MARK: - TTS Delegate

private class TTSDelegate: NSObject, NSSpeechSynthesizerDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Transcription Test Harness

@MainActor
final class TranscriptionTestHarness {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "TestHarness")

    private func log(_ message: String) {
        // Write to stderr (always unbuffered) to avoid stdout pipe buffering issues
        let line = "[TestHarness] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        logger.notice("\(message)")
    }

    // MARK: - TTS Audio Generation

    func generateTTSAudio(text: String, rate: Float) async throws -> [Float] {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts_\(UUID().uuidString).aiff")

        log("Generating TTS audio for \(text.count) chars at rate \(rate)")

        // Generate AIFF via NSSpeechSynthesizer
        let synth = NSSpeechSynthesizer()
        synth.rate = rate
        let delegate = TTSDelegate()
        synth.delegate = delegate

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            delegate.continuation = cont
            synth.startSpeaking(text, to: tempURL)
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Load AIFF and convert to 16kHz mono Float32
        let sourceFile = try AVAudioFile(forReading: tempURL)
        let sourceFormat = sourceFile.processingFormat
        let frameCount = AVAudioFrameCount(sourceFile.length)

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "TestHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create source buffer"])
        }
        try sourceFile.read(into: sourceBuffer)

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw NSError(domain: "TestHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create target format"])
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(domain: "TestHarness", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }

        let ratio = 16000.0 / sourceFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(frameCount) * ratio) + 100
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
            throw NSError(domain: "TestHarness", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create target buffer"])
        }

        var error: NSError?
        converter.convert(to: targetBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let error { throw error }

        guard let channelData = targetBuffer.floatChannelData else {
            throw NSError(domain: "TestHarness", code: 5, userInfo: [NSLocalizedDescriptionKey: "No channel data in converted buffer"])
        }

        let count = Int(targetBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))

        log("TTS generated \(count) samples (\(String(format: "%.2f", Double(count) / 16000.0))s)")
        return samples
    }

    // MARK: - Run Test

    func run(config: TestHarnessConfig, whisperManager: WhisperManager) async throws -> TestHarnessReport {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Generate TTS audio
        log("=== Test Harness Starting ===")
        log("Phrase: \(config.phrase)")
        let samples = try await generateTTSAudio(text: config.phrase, rate: config.voiceRate)

        let sampleRate = config.pipelineConfig.sampleRate
        let tickMs = config.pipelineConfig.tickMs
        let samplesPerTick = sampleRate * tickMs / 1000
        let audioDurationMs = (samples.count * 1000) / sampleRate

        log("Audio: \(samples.count) samples, \(audioDurationMs)ms, \(samplesPerTick) samples/tick")

        // Create fresh pipeline components
        let ringBuffer = AudioRingBuffer(
            capacity: config.pipelineConfig.windowSamples,
            sampleRate: sampleRate
        )
        let stabilizer = TranscriptStabilizer()
        let silenceDetector = SilenceDetector(
            silenceDurationMs: config.pipelineConfig.silenceMs
        )

        var tickMetricsList: [TickMetrics] = []
        var fullAudioSamples: [Float] = []
        var previousSpeculative = ""
        let maxBufferSamples = sampleRate * config.pipelineConfig.maxBufferMs / 1000

        // Warmup: decode maxBufferSamples of silence to pre-allocate Metal graph buffers.
        // Without this, the Metal allocator crashes after 3+ reallocations when graph
        // sizes change due to varying token counts across decodes.
        if !config.skipWarmup {
            log("Warming up Metal graph allocator...")
            let warmupSilence = [Float](repeating: 0, count: maxBufferSamples)
            _ = try await whisperManager.transcribeWindow(
                frames: warmupSilence,
                windowStartAbsMs: 0,
                prompt: nil
            )
            log("Warmup complete")
        }

        // Tick loop
        var tickIndex = 0
        var offset = 0

        while offset < samples.count {
            let end = min(offset + samplesPerTick, samples.count)
            let chunk = Array(samples[offset..<end])
            offset = end

            // Append to ring buffer and accumulator
            ringBuffer.append(samples: chunk)
            fullAudioSamples.append(contentsOf: chunk)

            // Optional real-time pacing
            if config.simulateRealTime {
                try await Task.sleep(nanoseconds: UInt64(tickMs) * 1_000_000)
            }

            // --- Silence detection: use ring buffer (recent window) ---
            let ringWindow = ringBuffer.getWindow()
            guard !ringWindow.pcm.isEmpty else {
                tickIndex += 1
                continue
            }

            let isSilent = silenceDetector.update(
                samples: ringWindow.pcm,
                currentAbsMs: ringWindow.windowEndAbsMs
            )

            if isSilent {
                let metrics = TickMetrics(
                    index: tickIndex,
                    audioPositionMs: ringWindow.windowEndAbsMs,
                    decodeLatencyMs: 0,
                    committed: stabilizer.state.rawCommitted,
                    speculative: stabilizer.state.rawSpeculative,
                    previousSpeculative: previousSpeculative,
                    isSilent: true
                )
                tickMetricsList.append(metrics)
                log("Tick \(tickIndex): SILENT @ \(ringWindow.windowEndAbsMs)ms")
                previousSpeculative = stabilizer.state.rawSpeculative
                tickIndex += 1
                continue
            }

            // --- Whisper decode: sliding window (last maxBufferMs of audio) ---
            // Skip decode until we have at least 1s of audio. Whisper requires
            // >= 1000ms input; shorter audio triggers Metal graph reallocations
            // that can corrupt the ggml allocator (node_27 invalid crash).
            let minSamples = sampleRate  // 1 second
            if fullAudioSamples.count < minSamples {
                let ms = (fullAudioSamples.count * 1000) / sampleRate
                log("Tick \(tickIndex): skipping decode (\(ms)ms < 1000ms minimum)")
                tickIndex += 1
                continue
            }

            let windowStart = max(0, fullAudioSamples.count - maxBufferSamples)
            let accPcm = Array(fullAudioSamples[windowStart...])
            let accStartMs = (windowStart * 1000) / sampleRate
            let accEndMs = (fullAudioSamples.count * 1000) / sampleRate

            // Build prompt from committed text
            let prompt = buildPrompt(
                from: stabilizer.state.rawCommitted,
                maxChars: config.pipelineConfig.maxPromptChars
            )

            // Decode
            let decodeStart = CFAbsoluteTimeGetCurrent()
            let result = try await whisperManager.transcribeWindow(
                frames: accPcm,
                windowStartAbsMs: accStartMs,
                prompt: prompt
            )
            let decodeLatencyMs = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000

            // Log raw decode tokens for diagnostics
            let commitHorizon = accEndMs - config.pipelineConfig.commitMarginMs
            var tokenSummary: [String] = []
            for seg in result.segments {
                if seg.tokens.isEmpty {
                    tokenSummary.append("[\(seg.text)|\(seg.startTimeMs + result.windowStartAbsMs)-\(seg.endTimeMs + result.windowStartAbsMs)]")
                } else {
                    for tok in seg.tokens {
                        let absEnd = tok.endTimeMs + result.windowStartAbsMs
                        let marker = absEnd <= commitHorizon ? "C" : "S"
                        tokenSummary.append("[\(tok.text.trimmingCharacters(in: .whitespaces))|\(absEnd)ms|\(marker)|p\(String(format: "%.2f", tok.probability))]")
                    }
                }
            }
            log("  Tokens: \(tokenSummary.joined(separator: " "))")
            log("  Horizon: \(commitHorizon)ms")

            // Skip hallucination-stalled decodes (>4s usually means Whisper
            // is generating garbage tokens on ambiguous audio)
            if decodeLatencyMs > 4000 {
                log("  SKIPPED (decode took \(String(format: "%.0f", decodeLatencyMs))ms)")
            } else {
                // Update stabilizer
                stabilizer.update(
                    decodeResult: result,
                    windowEndAbsMs: accEndMs,
                    commitMarginMs: config.pipelineConfig.commitMarginMs,
                    minTokenProbability: config.pipelineConfig.minTokenProbability
                )
            }

            let metrics = TickMetrics(
                index: tickIndex,
                audioPositionMs: accEndMs,
                decodeLatencyMs: decodeLatencyMs,
                committed: stabilizer.state.rawCommitted,
                speculative: stabilizer.state.rawSpeculative,
                previousSpeculative: previousSpeculative,
                isSilent: false
            )
            tickMetricsList.append(metrics)

            log("Tick \(tickIndex): \(String(format: "%.0f", decodeLatencyMs))ms | C: \"\(stabilizer.state.rawCommitted.suffix(60))\" | S: \"\(stabilizer.state.rawSpeculative.suffix(40))\"")

            previousSpeculative = stabilizer.state.rawSpeculative
            tickIndex += 1
        }

        // Finalize
        stabilizer.finalizeAll()
        let streamingResult = stabilizer.state.rawCommitted

        // Full-audio re-decode
        log("Running full-audio re-decode on \(fullAudioSamples.count) samples...")
        let fullDecodeResult = try await whisperManager.transcribeFull(frames: fullAudioSamples)

        // Simulate production post-processing matching TranscriptionPipeline.finalizeRecording():
        // When full decode succeeds, finalizeAll() is skipped (the full-audio result is
        // authoritative). Only apply finalizeAll() when falling back to streaming stabilizer.
        let productionResult: String
        if fullDecodeResult.isEmpty {
            // Full decode failed — production would use streaming + finalizeAll()
            let productionStabilizer = TranscriptStabilizer()
            productionStabilizer.state.rawCommitted = streamingResult
            productionStabilizer.finalizeAll()
            productionResult = productionStabilizer.state.rawCommitted
        } else {
            // Full decode succeeded — production uses it directly, no finalizeAll()
            productionResult = fullDecodeResult
        }

        let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // Detect flicker events
        let flickerEvents = detectFlicker(metrics: tickMetricsList)

        let report = TestHarnessReport(
            tickMetrics: tickMetricsList,
            streamingResult: streamingResult,
            fullDecodeResult: fullDecodeResult,
            productionResult: productionResult,
            referenceText: config.phrase,
            audioDurationMs: audioDurationMs,
            totalElapsedMs: totalElapsedMs,
            flickerEvents: flickerEvents
        )

        printReport(report)
        return report
    }

    // MARK: - Flicker Detection

    private func detectFlicker(metrics: [TickMetrics]) -> [Int] {
        var flickerIndices: [Int] = []
        var prevCommitted = ""

        for i in 0..<metrics.count {
            let m = metrics[i]
            guard !m.previousSpeculative.isEmpty else {
                prevCommitted = m.committed
                continue
            }

            let prevNormalized = m.previousSpeculative
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: .punctuationCharacters)
                .lowercased()
            guard !prevNormalized.isEmpty else {
                prevCommitted = m.committed
                continue
            }

            // If committed text grew, check if the previous speculative was absorbed
            // into the new committed text. This is normal forward progress, not flicker.
            let committedGrew = m.committed.count > prevCommitted.count
            if committedGrew {
                let newCommittedNorm = m.committed.lowercased()
                if newCommittedNorm.contains(prevNormalized) {
                    // Speculative text was absorbed into committed — forward progress, not flicker
                    prevCommitted = m.committed
                    continue
                }
            }

            // Check if previous speculative text was replaced (not found in current full text)
            let currentFull = m.committed + (m.speculative.isEmpty ? "" : " " + m.speculative)
            let normalized = currentFull.trimmingCharacters(in: .whitespaces).lowercased()

            if !normalized.contains(prevNormalized) {
                flickerIndices.append(m.index)
            }

            prevCommitted = m.committed
        }

        return flickerIndices
    }

    // MARK: - Prompt Building

    private func buildPrompt(from committed: String, maxChars: Int) -> String? {
        guard !committed.isEmpty else { return nil }
        guard committed.count > maxChars else { return committed }

        let suffix = String(committed.suffix(maxChars))
        if let dotRange = suffix.range(of: ". ", options: .literal) {
            return String(suffix[dotRange.upperBound...])
        }
        if let spaceRange = suffix.range(of: " ", options: .literal) {
            return String(suffix[spaceRange.upperBound...])
        }
        return suffix
    }

    // MARK: - WER Calculation

    /// Normalize text for WER comparison: lowercase, expand symbols,
    /// strip all non-alphanumeric characters so "dog." matches "dog",
    /// "$4,237" matches "4237", and "12%" matches "12 percent".
    private func normalizeForWER(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "%", with: " percent")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    /// Compute word error rate using Levenshtein distance on normalized word arrays.
    func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = normalizeForWER(reference)
        let hyp = normalizeForWER(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0.0 : 1.0 }

        // Levenshtein distance on word arrays
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

    // MARK: - Report

    private func printReport(_ report: TestHarnessReport) {
        log("=== Test Harness Report ===")
        log("Reference: \(report.referenceText)")
        log("Audio duration: \(report.audioDurationMs)ms")
        log("Total elapsed: \(String(format: "%.0f", report.totalElapsedMs))ms")
        log("")

        // Per-tick table
        log("Tick | AudioPos | Latency | Committed Delta              | Speculative                    | Flicker")
        log("---- | -------- | ------- | ---------------------------- | ------------------------------ | -------")

        var prevCommitted = ""
        for m in report.tickMetrics {
            let committedDelta = m.committed != prevCommitted
                ? String(m.committed.suffix(max(0, m.committed.count - prevCommitted.count)))
                : ""
            let isFlicker = report.flickerEvents.contains(m.index)
            let silentTag = m.isSilent ? " [SILENT]" : ""
            let deltaCol = (committedDelta.prefix(28) + silentTag).padding(toLength: 28, withPad: " ", startingAt: 0)
            let specCol = String(m.speculative.prefix(30)).padding(toLength: 30, withPad: " ", startingAt: 0)

            log(String(format: "%4d | %6dms | %5.0fms | %@ | %@ | %@",
                       m.index, m.audioPositionMs, m.decodeLatencyMs,
                       deltaCol, specCol, isFlicker ? "!" : ""))

            prevCommitted = m.committed
        }

        // Summary stats
        let decodeTicks = report.tickMetrics.filter { !$0.isSilent }
        let avgLatency = decodeTicks.isEmpty ? 0 :
            decodeTicks.map(\.decodeLatencyMs).reduce(0, +) / Double(decodeTicks.count)
        let maxLatency = decodeTicks.map(\.decodeLatencyMs).max() ?? 0

        let firstWordTick = report.tickMetrics.first { !$0.committed.isEmpty && !$0.isSilent }
        let timeToFirstWord = firstWordTick?.audioPositionMs ?? 0

        log("")
        log("=== Summary ===")
        log("Ticks: \(report.tickMetrics.count) total, \(decodeTicks.count) decoded, \(report.tickMetrics.count - decodeTicks.count) silent")
        log("Decode latency: avg \(String(format: "%.0f", avgLatency))ms, max \(String(format: "%.0f", maxLatency))ms")
        log("Time to first word: \(timeToFirstWord)ms")
        log("Flicker events: \(report.flickerEvents.count)")

        let streamingWER = wordErrorRate(reference: report.referenceText, hypothesis: report.streamingResult)
        let fullDecodeWER = wordErrorRate(reference: report.referenceText, hypothesis: report.fullDecodeResult)
        let productionWER = wordErrorRate(reference: report.referenceText, hypothesis: report.productionResult)
        log("Streaming WER: \(String(format: "%.1f", streamingWER * 100))%")
        log("Full decode WER: \(String(format: "%.1f", fullDecodeWER * 100))%")
        log("Production WER: \(String(format: "%.1f", productionWER * 100))% (after finalizeAll)")

        log("")
        log("Streaming result: \(report.streamingResult)")
        log("Full decode result: \(report.fullDecodeResult)")
        log("Production result: \(report.productionResult)")
        log("Reference text: \(report.referenceText)")
        log("=== End Report ===")
    }

    // MARK: - Test Phrase Library

    static let phraseLibrary: [TestPhrase] = [
        // Conversational (short, casual speech)
        TestPhrase(id: "conv-1", category: "conversational",
                   text: "I was thinking we could meet up on Thursday for lunch, maybe around noon. There's that new Italian place on Main Street.",
                   expectedDurationRange: 5...15),
        TestPhrase(id: "conv-2", category: "conversational",
                   text: "You know what, I actually forgot to mention that the meeting got moved to 3 o'clock instead of 2.",
                   expectedDurationRange: 5...15),
        TestPhrase(id: "conv-3", category: "conversational",
                   text: "Hey, did you see the email about the conference next week? Apparently they changed the venue to the downtown hotel.",
                   expectedDurationRange: 5...15),

        // Technical (domain vocabulary)
        TestPhrase(id: "tech-1", category: "technical",
                   text: "The server configuration requires updating the reverse proxy with new certificates and enabling protocol support for modern browsers.",
                   expectedDurationRange: 5...15),
        TestPhrase(id: "tech-2", category: "technical",
                   text: "The patient presents with lower extremity swelling, elevated blood pressure, and a resting heart rate of 78 beats per minute.",
                   expectedDurationRange: 5...15),

        // Narrative (storytelling, varied sentences)
        TestPhrase(id: "narr-1", category: "narrative",
                   text: "The old bookshop on the corner had been there for over 50 years. Its shelves were lined with dusty volumes that few people ever asked about. The owner, a quiet man with silver hair, spent his afternoons reading behind the counter.",
                   expectedDurationRange: 10...25),
        TestPhrase(id: "narr-2", category: "narrative",
                   text: "She walked through the garden as the last light of day filtered through the tall oak trees. The air smelled of jasmine and freshly cut grass. Somewhere in the distance, a church bell rang, marking the hour.",
                   expectedDurationRange: 8...20),

        // Numbers and dates
        TestPhrase(id: "num-1", category: "numbers",
                   text: "The total comes to $4,237 for 15 units, with delivery scheduled for March 14.",
                   expectedDurationRange: 5...15),
        TestPhrase(id: "num-2", category: "numbers",
                   text: "Flight 1742 departs at 6:45 in the morning from gate 22 and arrives at 10:30 local time.",
                   expectedDurationRange: 5...15),

        // Proper nouns (names, places)
        TestPhrase(id: "prop-1", category: "proper-nouns",
                   text: "Professor Catherine O'Brien from the University of Edinburgh published her findings in the Journal of Neuroscience last September.",
                   expectedDurationRange: 5...15),
        TestPhrase(id: "prop-2", category: "proper-nouns",
                   text: "The Amazon River flows through Brazil, Peru, and Colombia, making it one of the longest rivers in the world.",
                   expectedDurationRange: 5...15),

        // Instructions and lists
        TestPhrase(id: "inst-1", category: "instructions",
                   text: "First, preheat the oven to 375 degrees. Then combine 2 cups of flour, 1 teaspoon of baking soda, and half a teaspoon of salt in a large bowl.",
                   expectedDurationRange: 8...20),
        TestPhrase(id: "inst-2", category: "instructions",
                   text: "To reset your password, go to the settings page, click on security, select change password, enter your current password, then type your new password twice to confirm.",
                   expectedDurationRange: 5...20),

        // Weather and business (medium)
        TestPhrase(id: "weather-1", category: "conversational",
                   text: "The weather forecast calls for partly cloudy skies with temperatures reaching the mid-70s by afternoon. There is a slight chance of scattered showers in the evening.",
                   expectedDurationRange: 5...15),
        TestPhrase(id: "biz-1", category: "instructions",
                   text: "Please remember to submit your expense reports by the end of the month. All receipts must be attached and approved by your direct supervisor before processing.",
                   expectedDurationRange: 5...15),

        // Documentary and engineering
        TestPhrase(id: "doc-1", category: "narrative",
                   text: "The documentary explored the lives of three families living in different parts of the country, each facing unique challenges related to affordable housing and access to health care.",
                   expectedDurationRange: 5...15),
        TestPhrase(id: "eng-1", category: "technical",
                   text: "After reviewing the test results, the engineer determined that the component failure was caused by metal fatigue, likely due to repeated stress cycles over an extended period.",
                   expectedDurationRange: 5...15),

        // Journal (medium-long)
        TestPhrase(id: "journal-1", category: "narrative",
                   text: "She opened the old leather journal and began reading the entries from 1947. Each page was filled with careful observations about the local wildlife, the changing seasons, and the daily routines of village life.",
                   expectedDurationRange: 8...20),

        // Long mixed (extended dictation)
        TestPhrase(id: "long-1", category: "mixed",
                   text: "The city council met on Tuesday evening to discuss the proposed budget for the upcoming fiscal year. The mayor presented a plan that included increased funding for public transportation and road repairs. Several council members raised concerns about the impact on property taxes. After two hours of debate, they agreed to table the vote until the next meeting.",
                   expectedDurationRange: 15...35),
        TestPhrase(id: "long-2", category: "mixed",
                   text: "Good morning everyone, and welcome to the quarterly review. Last quarter we saw revenue increase by 12% compared to the same period last year. Our customer satisfaction scores remained high at 92%. However, we did see a slight uptick in support tickets, which the team is actively working to address. Looking ahead, we plan to launch two new product features by the end of next month.",
                   expectedDurationRange: 15...35),

        // 60-second extended dictation (~170 words). Deliberately includes natural
        // repeated phrases ("I think we", "we need to", "going to be") that
        // removeRepeatedPhrases(minLen:3) would incorrectly delete.
        TestPhrase(id: "long-60s-1", category: "mixed",
                   text: "Good morning everyone. I wanted to start today's meeting by going over the project timeline. I think we need to focus on three main areas this quarter. First, I think we need to improve the onboarding experience for new users. The current flow is confusing and we are seeing a 40% drop-off rate during registration. Sarah mentioned that she has some design mockups ready, and I think we should review those on Thursday. Second, we need to address the performance issues that customers have been reporting. The dashboard is loading slowly, especially for accounts with more than 500 transactions. The engineering team is going to be working on database optimization this sprint. We need to make sure we have proper monitoring in place before and after the changes. Finally, I want to talk about the upcoming conference in April. We need to prepare our presentation materials and I think we should highlight the new analytics features. The marketing team is going to be sending out invitations next week, so we need to finalize the speaker list by Friday. Does anyone have questions about these priorities?",
                   expectedDurationRange: 45...75),
    ]

    // MARK: - Batch Runner

    func runBatch(whisperManager: WhisperManager, pipelineConfig: PipelineConfig) async throws -> BatchReport {
        log("=== Batch Test Starting (\(Self.phraseLibrary.count) phrases) ===")

        // Warmup Metal graph once for the entire batch
        let maxBufferSamples = pipelineConfig.sampleRate * pipelineConfig.maxBufferMs / 1000
        log("Warming up Metal graph allocator...")
        let warmupSilence = [Float](repeating: 0, count: maxBufferSamples)
        _ = try await whisperManager.transcribeWindow(
            frames: warmupSilence,
            windowStartAbsMs: 0,
            prompt: nil
        )
        log("Warmup complete")

        var results: [PhraseResult] = []

        for (i, phrase) in Self.phraseLibrary.enumerated() {
            log("")
            log("=== Phrase \(i + 1)/\(Self.phraseLibrary.count): \(phrase.id) [\(phrase.category)] ===")

            var config = TestHarnessConfig(
                phrase: phrase.text,
                pipelineConfig: pipelineConfig
            )
            config.skipWarmup = true

            let report = try await run(config: config, whisperManager: whisperManager)

            let streamingWER = wordErrorRate(reference: phrase.text, hypothesis: report.streamingResult)
            let fullDecodeWER = wordErrorRate(reference: phrase.text, hypothesis: report.fullDecodeResult)
            let productionWER = wordErrorRate(reference: phrase.text, hypothesis: report.productionResult)
            let firstWordTick = report.tickMetrics.first { !$0.committed.isEmpty && !$0.isSilent }

            let result = PhraseResult(
                phrase: phrase,
                streamingWER: streamingWER,
                fullDecodeWER: fullDecodeWER,
                productionWER: productionWER,
                flickerCount: report.flickerEvents.count,
                timeToFirstWordMs: firstWordTick?.audioPositionMs ?? 0,
                audioDurationMs: report.audioDurationMs,
                passed: productionWER <= 0.05
            )
            results.append(result)

            let status = result.passed ? "PASS" : "FAIL"
            log("  -> [\(status)] Production WER: \(String(format: "%.1f", productionWER * 100))% | Full WER: \(String(format: "%.1f", fullDecodeWER * 100))% | Streaming WER: \(String(format: "%.1f", streamingWER * 100))%")
        }

        let meanStreaming = results.map(\.streamingWER).reduce(0, +) / Double(results.count)
        let meanFull = results.map(\.fullDecodeWER).reduce(0, +) / Double(results.count)
        let meanProd = results.map(\.productionWER).reduce(0, +) / Double(results.count)
        let maxFull = results.map(\.fullDecodeWER).max() ?? 0
        let maxProd = results.map(\.productionWER).max() ?? 0
        let passCount = results.filter(\.passed).count

        let batch = BatchReport(
            results: results,
            meanStreamingWER: meanStreaming,
            meanFullDecodeWER: meanFull,
            meanProductionWER: meanProd,
            maxFullDecodeWER: maxFull,
            maxProductionWER: maxProd,
            passCount: passCount,
            failCount: results.count - passCount
        )

        printBatchReport(batch)
        return batch
    }

    // MARK: - Batch Report

    private func printBatchReport(_ report: BatchReport) {
        log("")
        log("========================================")
        log("         BATCH TEST SUMMARY")
        log("========================================")
        log("")
        log("ID                    | Category       | Duration | Prod WER | Full WER | Stream WER | Flicker | Status")
        log("--------------------- | -------------- | -------- | -------- | -------- | ---------- | ------- | ------")

        for r in report.results {
            let id = r.phrase.id.padding(toLength: 21, withPad: " ", startingAt: 0)
            let cat = r.phrase.category.padding(toLength: 14, withPad: " ", startingAt: 0)
            let dur = "\(String(format: "%5.1f", Double(r.audioDurationMs) / 1000.0))s".padding(toLength: 8, withPad: " ", startingAt: 0)
            let prod = "\(String(format: "%5.1f", r.productionWER * 100))%".padding(toLength: 8, withPad: " ", startingAt: 0)
            let full = "\(String(format: "%5.1f", r.fullDecodeWER * 100))%".padding(toLength: 8, withPad: " ", startingAt: 0)
            let stream = "\(String(format: "%5.1f", r.streamingWER * 100))%".padding(toLength: 10, withPad: " ", startingAt: 0)
            let flicker = String(r.flickerCount).padding(toLength: 7, withPad: " ", startingAt: 0)
            let status = r.passed ? "PASS" : "FAIL"

            log("\(id) | \(cat) | \(dur) | \(prod) | \(full) | \(stream) | \(flicker) | \(status)")
        }

        log("")
        log("=== Aggregate Results ===")
        log("Phrases: \(report.results.count)")
        log("Pass rate: \(report.passCount)/\(report.results.count) (\(String(format: "%.0f", Double(report.passCount) / Double(report.results.count) * 100))%) [gate: production WER <= 5%]")
        log("Mean production WER: \(String(format: "%.1f", report.meanProductionWER * 100))% (what users get)")
        log("Max production WER: \(String(format: "%.1f", report.maxProductionWER * 100))%")
        log("Mean full-decode WER: \(String(format: "%.1f", report.meanFullDecodeWER * 100))% (raw Whisper)")
        log("Max full-decode WER: \(String(format: "%.1f", report.maxFullDecodeWER * 100))%")
        log("Mean streaming WER: \(String(format: "%.1f", report.meanStreamingWER * 100))%")

        if report.failCount > 0 {
            log("")
            log("=== Failing Phrases ===")
            for r in report.results where !r.passed {
                log("  \(r.phrase.id): prod \(String(format: "%.1f", r.productionWER * 100))% / raw \(String(format: "%.1f", r.fullDecodeWER * 100))% WER [\(r.phrase.category)]")
            }
        }

        log("")
        let overall = report.failCount == 0 ? "ALL PASSED" : "\(report.failCount) FAILED"
        log("=== \(overall) ===")
    }
}
