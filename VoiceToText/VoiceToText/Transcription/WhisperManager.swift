import Foundation
import SwiftWhisper
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
            return Whisper(fromFileURL: url, withParams: params)
        }.value

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

        logger.info("Starting transcription of \(frames.count) audio frames")

        let segments: [Segment]
        do {
            segments = try await whisper.transcribe(audioFrames: frames)
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            throw WhisperManagerError.transcriptionFailed(error.localizedDescription)
        }

        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Transcription complete: \(text.prefix(80))...")
        return text
    }

    // MARK: - Cleanup

    func unloadModel() {
        logger.info("Unloading Whisper model")
        whisper = nil
    }
}
