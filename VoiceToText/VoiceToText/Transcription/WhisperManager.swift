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

// MARK: - WhisperManager

actor WhisperManager {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "WhisperManager")

    private var whisper: Whisper?
    var isModelLoaded: Bool { whisper != nil }

    // MARK: - Model Loading

    func loadModel(url: URL) async throws {
        logger.info("Loading Whisper model from \(url.lastPathComponent)")

        if whisper != nil {
            logger.info("Unloading previous model before loading new one")
            whisper = nil
        }

        // Model loading is synchronous in SwiftWhisper, so run on a detached task
        // to avoid blocking the actor or the caller's executor.
        let loadedWhisper = await Task.detached(priority: .userInitiated) {
            let params = WhisperParams(strategy: .greedy)
            params.language = .english

            // Use all available cores for maximum speed
            params.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)

            // Skip segment boundary detection — we want one result fast
            params.single_segment = true

            // Disable temperature fallback retries (default retries up to 3x on low confidence)
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

            return Whisper(fromFileURL: url, withParams: params)
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

        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Set initial_prompt for decoder context continuity between chunks
        if let previousText, !previousText.isEmpty {
            let promptCString = strdup(previousText)
            whisper.params.initial_prompt = UnsafePointer(promptCString)
            defer { free(promptCString) }
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

        // Reset initial_prompt after use
        whisper.params.initial_prompt = nil

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Chunk transcription took \(String(format: "%.3f", elapsed))s for \(String(format: "%.2f", audioDuration))s audio")
        return text
    }

    // MARK: - Cleanup

    func unloadModel() {
        logger.info("Unloading Whisper model")
        whisper = nil
    }
}
