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
    let referenceText: String
    let audioDurationMs: Int
    let totalElapsedMs: Double
    let flickerEvents: [Int]  // tick indices where flicker occurred
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
        log("Warming up Metal graph allocator...")
        let warmupSilence = [Float](repeating: 0, count: maxBufferSamples)
        _ = try await whisperManager.transcribeWindow(
            frames: warmupSilence,
            windowStartAbsMs: 0,
            prompt: nil
        )
        log("Warmup complete")

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

        let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // Detect flicker events
        let flickerEvents = detectFlicker(metrics: tickMetricsList)

        let report = TestHarnessReport(
            tickMetrics: tickMetricsList,
            streamingResult: streamingResult,
            fullDecodeResult: fullDecodeResult,
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

    /// Compute word error rate using Levenshtein distance on normalized word arrays.
    private func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = reference.lowercased().split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        let hyp = hypothesis.lowercased().split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
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
        log("Streaming WER: \(String(format: "%.1f", streamingWER * 100))%")
        log("Full decode WER: \(String(format: "%.1f", fullDecodeWER * 100))%")

        log("")
        log("Streaming result: \(report.streamingResult)")
        log("Full decode result: \(report.fullDecodeResult)")
        log("Reference text: \(report.referenceText)")
        log("=== End Report ===")
    }
}
