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

    // MARK: - Pipeline Components

    private let config = PipelineConfig()
    private let stabilizer = TranscriptStabilizer()
    private let silenceDetector = SilenceDetector()
    private var ringBuffer: AudioRingBuffer?

    // MARK: - Tick Loop State

    private var tickTimer: Timer?
    private var isDecoding = false
    private var needsRedecode = false

    // MARK: - Focus Tracking

    private var frontmostApp: NSRunningApplication?

    // MARK: - LLM Burst State

    private var lastLLMCleanCharCount = 0

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

        Task {
            await loadSelectedModel()
        }

        // Pre-load local LLM if configured
        Task {
            let llmConfig = LLMConfig.load()
            if llmConfig.isEnabled && llmConfig.provider == .local {
                await LocalLLMManager.shared.prepareModel(
                    modelId: llmConfig.localModelId,
                    systemPrompt: llmConfig.systemPrompt
                )
            }
        }
    }

    func reloadHotKeys() {
        hotKeyManager.setup()
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

        let modelURL = modelManager.activeModelFileURL(for: model, fastMode: appState.fastMode)
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

        // Record frontmost app for paste focus restoration
        frontmostApp = clipboardPaster.recordFrontmostApp()

        // Reset pipeline state
        stabilizer.reset()
        silenceDetector.reset()
        isDecoding = false
        needsRedecode = false
        lastLLMCleanCharCount = 0
        appState.resetStreamingText()

        // Create ring buffer for this session
        let buffer = AudioRingBuffer(capacity: config.windowSamples, sampleRate: config.sampleRate)
        ringBuffer = buffer

        do {
            try audioRecorder.startCapture(ringBuffer: buffer)
            appState.transitionTo(.recording)
            RecordingOverlayWindow.shared.show()

            // Start tick timer
            tickTimer = Timer.scheduledTimer(withTimeInterval: config.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }

            logger.info("Recording started (sliding window mode, tick: \(self.config.tickMs)ms, window: \(self.config.windowMs)ms)")
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

        // Stop tick timer
        tickTimer?.invalidate()
        tickTimer = nil

        // Stop audio capture
        audioRecorder.stopCapture()

        // Begin finalization
        Task {
            await finalizeRecording()
        }
    }

    func cancelRecording() {
        if appState.recordingState == .recording {
            tickTimer?.invalidate()
            tickTimer = nil
            audioRecorder.stopCapture()
        }
        isDecoding = false
        needsRedecode = false
        stabilizer.reset()
        silenceDetector.reset()
        ringBuffer = nil
        frontmostApp = nil
        appState.resetStreamingText()
        appState.transitionTo(.idle)
        RecordingOverlayWindow.shared.hide()
        logger.info("Recording cancelled")
    }

    // MARK: - Tick Loop

    private func tick() {
        // Backpressure: if a decode is already in flight, mark that we need a redecode
        if isDecoding {
            needsRedecode = true
            return
        }

        guard let window = audioRecorder.getLatestWindow(),
              !window.pcm.isEmpty else {
            return
        }

        // Check for silence
        if silenceDetector.update(samples: window.pcm, currentAbsMs: window.windowEndAbsMs) {
            return  // Silence detected, skip decode to save resources
        }

        isDecoding = true

        // Build prompt from committed text
        let committed = stabilizer.state.rawCommitted
        let prompt: String?
        if committed.isEmpty {
            prompt = nil
        } else if committed.count <= config.maxPromptChars {
            prompt = committed
        } else {
            prompt = String(committed.suffix(config.maxPromptChars))
        }

        let windowStartAbsMs = window.windowStartAbsMs
        let windowEndAbsMs = window.windowEndAbsMs
        let frames = window.pcm
        let commitMarginMs = config.commitMarginMs

        Task {
            do {
                let result = try await whisperManager.transcribeWindow(
                    frames: frames,
                    windowStartAbsMs: windowStartAbsMs,
                    prompt: prompt
                )

                await MainActor.run {
                    self.stabilizer.update(
                        decodeResult: result,
                        windowEndAbsMs: windowEndAbsMs,
                        commitMarginMs: commitMarginMs
                    )
                    self.updateUIFromStabilizer()
                    self.isDecoding = false

                    if self.needsRedecode {
                        self.needsRedecode = false
                        self.tick()
                    }

                    self.maybeRunLLMBurstClean()
                }
            } catch {
                await MainActor.run {
                    self.isDecoding = false
                    self.logger.error("Tick decode failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - UI Updates

    private func updateUIFromStabilizer() {
        let state = stabilizer.state
        appState.committedText = state.cleanedCommitted ?? state.rawCommitted
        appState.speculativeText = state.rawSpeculative
    }

    // MARK: - LLM Burst Cleaning

    private func maybeRunLLMBurstClean() {
        let llmConfig = LLMConfig.load()
        guard llmConfig.isEnabled && llmConfig.isValid else { return }

        let committed = stabilizer.state.rawCommitted
        let newChars = committed.count - lastLLMCleanCharCount
        guard newChars > 200 else { return }

        lastLLMCleanCharCount = committed.count

        // Clean only the new portion at sentence boundary
        let postProcessor = LLMPostProcessor(config: llmConfig)
        Task {
            let cleaned = await postProcessor.processChunked(rawText: committed)
            await MainActor.run {
                self.stabilizer.state.cleanedCommitted = cleaned
                self.updateUIFromStabilizer()
            }
        }
    }

    // MARK: - Finalization

    private func finalizeRecording() async {
        appState.transitionTo(.transcribing)

        // Wait for any in-flight decode to complete
        while isDecoding {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        // Final decode with full window, commit everything (margin=0)
        if let window = ringBuffer?.getWindow(), !window.pcm.isEmpty {
            do {
                let result = try await whisperManager.transcribeWindow(
                    frames: window.pcm,
                    windowStartAbsMs: window.windowStartAbsMs,
                    prompt: stabilizer.state.rawCommitted.isEmpty ? nil : String(stabilizer.state.rawCommitted.suffix(config.maxPromptChars))
                )
                stabilizer.update(
                    decodeResult: result,
                    windowEndAbsMs: window.windowEndAbsMs,
                    commitMarginMs: 0  // Commit everything
                )
            } catch {
                logger.error("Final decode failed: \(error.localizedDescription)")
            }
        }

        // Finalize all speculative text as committed
        stabilizer.finalizeAll()
        updateUIFromStabilizer()

        let rawText = stabilizer.state.rawCommitted

        guard !rawText.isEmpty else {
            logger.info("Recording produced empty transcription")
            cleanup()
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
            finalText = await postProcessor.processChunked(rawText: rawText)
            logger.info("LLM processed: '\(rawText.prefix(40))' → '\(finalText.prefix(40))'")
        }

        // Paste via clipboard with focus tracking
        appState.lastTranscription = finalText

        RecordingOverlayWindow.shared.hide()

        // Brief settle time for window server
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let pasteResult = await clipboardPaster.paste(text: finalText, targetApp: frontmostApp)

        switch pasteResult {
        case .pasted:
            break
        case .copiedOnly(let reason):
            appState.toastMessage = "Copied to clipboard (paste manually)"
            logger.warning("Paste failed: \(reason). Text on clipboard.")
            RecordingOverlayWindow.shared.showToast("Copied — paste with ⌘V")
        }

        cleanup()
        appState.transitionTo(.idle)
        logger.info("Pipeline complete, final text: \(finalText.prefix(80))")
    }

    // MARK: - Cleanup

    private func cleanup() {
        stabilizer.reset()
        silenceDetector.reset()
        ringBuffer = nil
        frontmostApp = nil
        isDecoding = false
        needsRedecode = false
        lastLLMCleanCharCount = 0
    }
}
