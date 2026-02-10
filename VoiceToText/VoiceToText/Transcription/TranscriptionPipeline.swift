import Foundation
import AppKit
import os

@MainActor
final class TranscriptionPipeline: ObservableObject {
    static let shared = TranscriptionPipeline()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "TranscriptionPipeline")

    // MARK: - Dependencies

    private let audioRecorder = AudioRecorder()
    private let whisperManager = WhisperManager()
    private let clipboardPaster = ClipboardPaster()

    private let modelManager = ModelManager.shared
    private let appState = AppState.shared
    private let hotKeyManager = HotKeyManager()

    // MARK: - State

    @Published var isModelReady: Bool = false

    // MARK: - App Lifecycle

    func setup() {
        hotKeyManager.onStartRecording = { [weak self] in
            self?.startRecording()
        }
        hotKeyManager.onStopRecording = { [weak self] in
            guard self?.appState.recordingState == .recording else { return }
            self?.stopRecording()
        }
        hotKeyManager.setup()
        logger.info("TranscriptionPipeline setup complete")

        // Load model in background
        Task {
            await loadSelectedModel()
        }
    }

    // MARK: - Model Loading

    func loadSelectedModel() async {
        guard let model = appState.selectedModel else {
            logger.warning("No model selected")
            return
        }

        guard modelManager.isModelDownloaded(model) else {
            logger.warning("Selected model \(model.id) is not downloaded")
            appState.transitionTo(.error("Model not downloaded. Please download a model in Settings."))
            return
        }

        let modelURL = modelManager.modelFileURL(for: model)
        do {
            try await whisperManager.loadModel(url: modelURL)
            isModelReady = true
            logger.info("Model \(model.id) loaded and ready")
        } catch {
            isModelReady = false
            logger.error("Failed to load model: \(error.localizedDescription)")
            appState.transitionTo(.error("Failed to load model: \(error.localizedDescription)"))
        }
    }

    // MARK: - Recording Control

    func startRecording() {
        guard appState.recordingState == .idle else {
            logger.warning("Cannot start recording in state: \(String(describing: self.appState.recordingState))")
            return
        }

        do {
            try audioRecorder.startCapture()
            appState.transitionTo(.recording)
            RecordingOverlayWindow.shared.show()
            logger.info("Recording started")
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            appState.transitionTo(.error(error.localizedDescription))
        }
    }

    func stopRecording() {
        guard appState.recordingState == .recording else {
            logger.warning("Cannot stop recording in state: \(String(describing: self.appState.recordingState))")
            return
        }

        let samples = audioRecorder.stopCapture()
        logger.info("Captured \(samples.count) samples")

        guard !samples.isEmpty else {
            appState.transitionTo(.idle)
            RecordingOverlayWindow.shared.hide()
            return
        }

        // Begin transcription pipeline
        Task {
            await processAudio(samples: samples)
        }
    }

    func cancelRecording() {
        if appState.recordingState == .recording {
            _ = audioRecorder.stopCapture()
        }
        appState.transitionTo(.idle)
        RecordingOverlayWindow.shared.hide()
        logger.info("Recording cancelled")
    }

    // MARK: - Processing Pipeline

    private func processAudio(samples: [Float]) async {
        // Step 1: Transcribe
        appState.transitionTo(.transcribing)

        let rawText: String
        do {
            rawText = try await whisperManager.transcribe(frames: samples)
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            appState.transitionTo(.error("Transcription failed: \(error.localizedDescription)"))
            RecordingOverlayWindow.shared.hide()
            return
        }

        guard !rawText.isEmpty else {
            logger.info("Transcription returned empty text")
            appState.transitionTo(.idle)
            RecordingOverlayWindow.shared.hide()
            return
        }

        // Step 2: Optional LLM post-processing
        var finalText = rawText
        let llmConfig = LLMConfig.load()

        if llmConfig.isEnabled && llmConfig.isValid {
            appState.transitionTo(.processing)
            let postProcessor = LLMPostProcessor(config: llmConfig)
            finalText = await postProcessor.process(rawText: rawText)
            logger.info("LLM processed: '\(rawText.prefix(40))' → '\(finalText.prefix(40))'")
        }

        // Step 3: Paste via clipboard
        appState.lastTranscription = finalText

        // Hide overlay (non-activating panel, so target app retains focus)
        RecordingOverlayWindow.shared.hide()

        // Brief settle time for window server
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        await clipboardPaster.paste(text: finalText)

        // Done
        appState.transitionTo(.idle)
        logger.info("Pipeline complete, pasted text: \(finalText.prefix(80))")
    }
}

