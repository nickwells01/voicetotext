import Foundation
import os

// MARK: - WhisperManager Errors

enum WhisperManagerError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No Whisper model is loaded. Please download and select a model first."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .emptyAudio:
            return "No audio data to transcribe."
        }
    }
}

// MARK: - Decode Result

struct DecodeResult {
    let segments: [TranscriptionSegment]
    let windowStartAbsMs: Int
}

// MARK: - WhisperManager

actor WhisperManager {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "WhisperManager")

    private var whisper: Whisper?
    var isModelLoaded: Bool { whisper != nil }

    // MARK: - Model Loading

    private var currentLanguage: WhisperLanguage = .english

    func loadModel(url: URL, language: WhisperLanguage = .english, useGPU: Bool = true) async throws {
        logger.info("Loading Whisper model from \(url.lastPathComponent)")

        if whisper != nil {
            logger.info("Unloading previous model before loading new one")
            whisper = nil
        }

        self.currentLanguage = language

        // Model loading is synchronous in SwiftWhisper, so run on a detached task
        // to avoid blocking the actor or the caller's executor.
        let lang = language
        let gpu = useGPU
        let loadedWhisper = await Task.detached(priority: .userInitiated) {
            let params = WhisperParams(strategy: .greedy)
            params.language = lang

            // Use all available cores for maximum speed
            params.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)

            // Disable temperature fallback retries for streaming (speed matters)
            params.temperature_inc = 0.0

            // Skip candidate comparison (default best_of=2)
            params.greedy.best_of = 1

            // Suppress blank/silence hallucinations
            params.suppress_blank = true

            // Disable all console printing for speed
            params.print_progress = false
            params.print_timestamps = false
            params.print_realtime = false
            params.print_special = false

            return Whisper(fromFileURL: url, withParams: params, useGPU: gpu)
        }.value

        guard let loadedWhisper else {
            throw WhisperManagerError.transcriptionFailed("Failed to initialize whisper context from \(url.lastPathComponent)")
        }

        self.whisper = loadedWhisper
        logger.info("Whisper model loaded successfully")
    }

    // MARK: - Transcription

    func transcribe(frames: [Float]) async throws -> String {
        guard let whisper else {
            logger.error("Attempted transcription without a loaded model")
            throw WhisperManagerError.modelNotLoaded
        }

        guard !frames.isEmpty else {
            logger.warning("Transcription called with empty audio frames")
            throw WhisperManagerError.emptyAudio
        }

        let audioDuration = Double(frames.count) / 16000.0
        logger.info("Starting transcription of \(frames.count) frames (\(String(format: "%.2f", audioDuration))s audio)")

        let startTime = CFAbsoluteTimeGetCurrent()

        let segments: [Segment]
        do {
            segments = try await whisper.transcribe(audioFrames: frames)
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            throw WhisperManagerError.transcriptionFailed(error.localizedDescription)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        let raw = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip Whisper's silence hallucination artifacts (sequences of 2+ dots)
        let text = raw.replacingOccurrences(of: "\\.{2,}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Transcription took \(String(format: "%.3f", elapsed))s for \(String(format: "%.2f", audioDuration))s audio (RTF: \(String(format: "%.2f", elapsed / max(audioDuration, 0.001)))x)")
        return text
    }

    // MARK: - Chunk Transcription (Streaming)

    /// Transcribe a single chunk of audio, optionally using previous text as decoder context.
    func transcribeChunk(frames: [Float], previousText: String? = nil) async throws -> String {
        guard let whisper else {
            throw WhisperManagerError.modelNotLoaded
        }

        guard !frames.isEmpty else {
            return ""
        }

        // Set initial_prompt for decoder context continuity between chunks.
        // The strdup'd string must live until after transcribe() returns,
        // so defer { free } is at function scope (not inside the if block).
        var promptCString: UnsafeMutablePointer<CChar>?
        if let previousText, !previousText.isEmpty {
            promptCString = strdup(previousText)
            whisper.params.initial_prompt = UnsafePointer(promptCString)
        }
        defer {
            if promptCString != nil { free(promptCString) }
            whisper.params.initial_prompt = nil
        }

        let audioDuration = Double(frames.count) / 16000.0
        let startTime = CFAbsoluteTimeGetCurrent()

        let segments: [Segment]
        do {
            segments = try await whisper.transcribe(audioFrames: frames)
        } catch {
            logger.error("Chunk transcription failed: \(error.localizedDescription)")
            throw WhisperManagerError.transcriptionFailed(error.localizedDescription)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let raw = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip Whisper's silence hallucination artifacts (sequences of 2+ dots)
        let text = raw.replacingOccurrences(of: "\\.{2,}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Chunk transcription took \(String(format: "%.3f", elapsed))s for \(String(format: "%.2f", audioDuration))s audio")
        return text
    }

    // MARK: - Window Transcription (Sliding Window Pipeline)

    /// Transcribe a sliding window of audio with token-level timestamps enabled.
    func transcribeWindow(
        frames: [Float],
        windowStartAbsMs: Int,
        prompt: String?
    ) async throws -> DecodeResult {
        guard let whisper else {
            throw WhisperManagerError.modelNotLoaded
        }

        guard !frames.isEmpty else {
            return DecodeResult(segments: [], windowStartAbsMs: windowStartAbsMs)
        }

        // Enable token data (probabilities). We do NOT need token_timestamps
        // (dtw-based timing) since the stabilizer only uses token probabilities.
        // token_timestamps triggers whisper_exp_compute_token_level_timestamps()
        // which has an out-of-bounds crash in certain edge cases.
        whisper.params.token_timestamps = false

        // Limit token count to prevent hallucination loops and bound decode time.
        // 50 tokens covers ~30 words of real speech for a 12s window.
        whisper.params.single_segment = true
        whisper.params.max_tokens = 50

        // Set initial_prompt for decoder context continuity
        var promptCString: UnsafeMutablePointer<CChar>?
        if let prompt, !prompt.isEmpty {
            promptCString = strdup(prompt)
            whisper.params.initial_prompt = UnsafePointer(promptCString)
        }
        defer {
            if promptCString != nil { free(promptCString) }
            whisper.params.initial_prompt = nil
            // Restore settings for non-window callers
            whisper.params.token_timestamps = false
            whisper.params.single_segment = false
            whisper.params.max_tokens = 0
        }

        let audioDuration = Double(frames.count) / 16000.0
        let startTime = CFAbsoluteTimeGetCurrent()

        let segments: [TranscriptionSegment]
        do {
            segments = try await whisper.transcribeWithTokens(audioFrames: frames)
        } catch {
            logger.error("Window transcription failed: \(error.localizedDescription)")
            throw WhisperManagerError.transcriptionFailed(error.localizedDescription)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("Window transcription took \(String(format: "%.3f", elapsed))s for \(String(format: "%.2f", audioDuration))s audio (RTF: \(String(format: "%.2f", elapsed / max(audioDuration, 0.001)))x)")

        return DecodeResult(segments: segments, windowStartAbsMs: windowStartAbsMs)
    }

    // MARK: - Full Audio Decode (Finalization)

    /// Perform a single authoritative decode of the full recording audio.
    /// Unlike `transcribeWindow`, this allows multi-segment output (no `single_segment`)
    /// and skips token-level timestamps, letting Whisper.cpp handle long audio naturally.
    func transcribeFull(frames: [Float]) async throws -> String {
        guard let whisper else {
            throw WhisperManagerError.modelNotLoaded
        }
        guard !frames.isEmpty else { return "" }

        // Enable temperature fallback for finalization (retry low-confidence segments)
        let savedTempInc = whisper.params.temperature_inc
        whisper.params.temperature_inc = 0.2
        whisper.params.single_segment = false
        whisper.params.token_timestamps = false
        whisper.params.initial_prompt = nil

        defer {
            whisper.params.temperature_inc = savedTempInc
            whisper.params.token_timestamps = false
        }

        let audioDuration = Double(frames.count) / 16000.0
        let startTime = CFAbsoluteTimeGetCurrent()

        let segments: [Segment]
        do {
            segments = try await whisper.transcribe(audioFrames: frames)
        } catch {
            logger.error("Full-audio transcription failed: \(error.localizedDescription)")
            throw WhisperManagerError.transcriptionFailed(error.localizedDescription)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let raw = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.replacingOccurrences(of: "\\.{2,}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        logger.info("Full-audio decode: \(String(format: "%.3f", elapsed))s for \(String(format: "%.2f", audioDuration))s audio → \(text.count) chars")
        return text
    }

    // MARK: - Cleanup

    func unloadModel() {
        logger.info("Unloading Whisper model")
        whisper = nil
    }
}
