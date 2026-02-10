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

    // MARK: - Streaming State

    /// Accumulated chunk transcriptions during streaming recording
    private var chunkTexts: [String] = []
    /// Last chunk's text used as decoder context for next chunk
    private var lastChunkText: String = ""
    /// Task for in-flight chunk transcription
    private var chunkTranscriptionTask: Task<Void, Never>?

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

        // Reset streaming state
        chunkTexts = []
        lastChunkText = ""
        chunkTranscriptionTask = nil

        // Wire up chunk emission for streaming transcription
        audioRecorder.onChunkReady = { [weak self] chunk in
            self?.processChunk(chunk)
        }

        do {
            try audioRecorder.startCapture()
            appState.transitionTo(.recording)
            RecordingOverlayWindow.shared.show()
            logger.info("Recording started (streaming mode)")
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

        // Get only the unprocessed tail (samples after last emitted chunk)
        let tailSamples = audioRecorder.stopCaptureAndGetTail()

        // Begin streaming finalization pipeline
        Task {
            await finalizeStreamingTranscription(tailSamples: tailSamples)
        }
    }

    func cancelRecording() {
        if appState.recordingState == .recording {
            _ = audioRecorder.stopCapture()
        }
        chunkTranscriptionTask?.cancel()
        chunkTranscriptionTask = nil
        chunkTexts = []
        lastChunkText = ""
        audioRecorder.onChunkReady = nil
        appState.transitionTo(.idle)
        RecordingOverlayWindow.shared.hide()
        logger.info("Recording cancelled")
    }

    // MARK: - Streaming Chunk Processing

    /// Called during recording when a 3-second chunk is ready
    private func processChunk(_ chunk: [Float]) {
        let previousText = lastChunkText
        chunkTranscriptionTask = Task {
            do {
                let text = try await whisperManager.transcribeChunk(frames: chunk, previousText: previousText)
                guard !text.isEmpty else { return }
                chunkTexts.append(text)
                lastChunkText = text
                logger.info("Chunk \(self.chunkTexts.count) transcribed: \(text.prefix(60))")
            } catch {
                logger.error("Chunk transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Streaming Finalization

    private func finalizeStreamingTranscription(tailSamples: [Float]) async {
        appState.transitionTo(.transcribing)

        // Wait for any in-flight chunk transcription to complete
        if let inFlightTask = chunkTranscriptionTask {
            await inFlightTask.value
            chunkTranscriptionTask = nil
        }

        // Transcribe the tail (audio after last emitted chunk)
        if !tailSamples.isEmpty {
            do {
                let tailText = try await whisperManager.transcribeChunk(
                    frames: tailSamples,
                    previousText: lastChunkText
                )
                if !tailText.isEmpty {
                    chunkTexts.append(tailText)
                    logger.info("Tail transcribed: \(tailText.prefix(60))")
                }
            } catch {
                logger.error("Tail transcription failed: \(error.localizedDescription)")
            }
        }

        // Join all chunk texts and deduplicate word boundaries
        let rawText = joinChunkTexts(chunkTexts)

        // Clean up streaming state
        audioRecorder.onChunkReady = nil
        chunkTexts = []
        lastChunkText = ""

        guard !rawText.isEmpty else {
            logger.info("Streaming transcription returned empty text")
            appState.transitionTo(.idle)
            RecordingOverlayWindow.shared.hide()
            return
        }

        // Optional LLM post-processing
        var finalText = rawText
        let llmConfig = LLMConfig.load()

        if llmConfig.isEnabled && llmConfig.isValid {
            appState.transitionTo(.processing)
            let postProcessor = LLMPostProcessor(config: llmConfig)
            finalText = await postProcessor.process(rawText: rawText)
            logger.info("LLM processed: '\(rawText.prefix(40))' → '\(finalText.prefix(40))'")
        }

        // Paste via clipboard
        appState.lastTranscription = finalText

        RecordingOverlayWindow.shared.hide()

        // Brief settle time for window server
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        await clipboardPaster.paste(text: finalText)

        appState.transitionTo(.idle)
        logger.info("Streaming pipeline complete, pasted text: \(finalText.prefix(80))")
    }

    // MARK: - Chunk Text Joining

    /// Join chunk texts with word boundary deduplication.
    /// The 200ms overlap between chunks can cause repeated words at boundaries.
    private func joinChunkTexts(_ texts: [String]) -> String {
        guard !texts.isEmpty else { return "" }
        guard texts.count > 1 else { return texts[0] }

        var result = texts[0]

        for i in 1..<texts.count {
            let currentText = texts[i]
            guard !currentText.isEmpty else { continue }

            let prevWords = result.split(separator: " ")
            let currWords = currentText.split(separator: " ")

            guard !prevWords.isEmpty, !currWords.isEmpty else {
                result += " " + currentText
                continue
            }

            // Check if the first 1-3 words of the current chunk match the last words of the previous result
            // This handles overlap-caused duplication
            var overlapCount = 0
            let maxOverlap = min(3, min(prevWords.count, currWords.count))

            for checkLen in (1...maxOverlap).reversed() {
                let prevTail = prevWords.suffix(checkLen).map(String.init)
                let currHead = currWords.prefix(checkLen).map(String.init)
                if prevTail.map({ $0.lowercased() }) == currHead.map({ $0.lowercased() }) {
                    overlapCount = checkLen
                    break
                }
            }

            if overlapCount > 0 {
                let deduplicated = currWords.dropFirst(overlapCount).joined(separator: " ")
                if !deduplicated.isEmpty {
                    result += " " + deduplicated
                }
            } else {
                result += " " + currentText
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

