import Foundation
import AppKit
import os
import AVFoundation

@MainActor
final class TranscriptionPipeline: ObservableObject {
    static let shared = TranscriptionPipeline()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "TranscriptionPipeline")

    // MARK: - Dependencies

    let whisperManager = WhisperManager()
    private let modelManager = ModelManager.shared
    private let appState = AppState.shared
    private let hotKeyManager = HotKeyManager()

    // MARK: - Extracted Components

    private let recordingSession = RecordingSession()
    private let pasteCoordinator = PasteCoordinator()

    // MARK: - Pipeline Components

    private let stabilizer = TranscriptStabilizer()
    private let silenceDetector = SilenceDetector()
    private let fillerWordFilter = FillerWordFilter()

    // MARK: - Tick Loop State

    private var isDecoding = false
    private var needsRedecode = false

    // MARK: - LLM Config Cache

    private var cachedLLMConfig: LLMConfig?

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
            if appState.llmConfig.isEnabled && appState.llmConfig.provider == .local {
                await LocalLLMManager.shared.prepareModel(
                    modelId: appState.llmConfig.localModelId,
                    systemPrompt: appState.llmConfig.systemPrompt
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
        let language = WhisperLanguage.from(code: appState.selectedLanguage)
        do {
            try await whisperManager.loadModel(url: modelURL, language: language)
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

        // Reset pipeline state
        stabilizer.reset()
        silenceDetector.reset()
        isDecoding = false
        needsRedecode = false
        var llmConfig = appState.llmConfig
        // Enforce privacy mode: force local provider when privacy mode is on
        if appState.privacyMode && llmConfig.provider == .remote {
            llmConfig.provider = .local
        }
        cachedLLMConfig = llmConfig

        // Detect and show app context (if enabled)
        if appState.appContextEnabled {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let context = AppContextDetector.detect(bundleIdentifier: frontmost?.bundleIdentifier)
            if context != .general {
                appState.detectedAppContext = context.displayName
            } else {
                appState.detectedAppContext = nil
            }
        } else {
            appState.detectedAppContext = nil
        }

        appState.resetStreamingText()

        do {
            recordingSession.onTick = { [weak self] in self?.tick() }
            try recordingSession.start(config: appState.pipelineConfig, clipboardPaster: ClipboardPaster())
            appState.transitionTo(.recording)
            RecordingOverlayWindow.shared.show()
            playStartSound()
            logger.info("Recording started (sliding window mode, tick: \(self.appState.pipelineConfig.tickMs)ms, window: \(self.appState.pipelineConfig.windowMs)ms)")
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

        recordingSession.stop()
        playStopSound()

        Task {
            await finalizeRecording()
        }
    }

    func cancelRecording() {
        if appState.recordingState == .recording {
            recordingSession.stop()
        }
        isDecoding = false
        needsRedecode = false
        stabilizer.reset()
        silenceDetector.reset()
        recordingSession.cleanup()
        cachedLLMConfig = nil
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

        // --- Silence detection: use ring buffer (recent 8s window) ---
        guard let ringWindow = recordingSession.audioRecorder.getLatestWindow(),
              !ringWindow.pcm.isEmpty else {
            return
        }

        let isSilent = silenceDetector.update(samples: ringWindow.pcm, currentAbsMs: ringWindow.windowEndAbsMs)

        // Update waveform visualization (rolling buffer of recent RMS levels)
        let maxLevels = 30
        appState.audioLevels.append(silenceDetector.lastRMS)
        if appState.audioLevels.count > maxLevels {
            appState.audioLevels.removeFirst(appState.audioLevels.count - maxLevels)
        }

        if isSilent {
            return  // Silence detected, skip decode to save resources
        }

        // --- Whisper decode: use accumulated window (grows until trimmed) ---
        guard let accWindow = recordingSession.audioRecorder.getAccumulatedWindow() else { return }

        isDecoding = true

        let prompt = buildPrompt(from: stabilizer.state.rawCommitted)

        let windowStartAbsMs = accWindow.windowStartAbsMs
        let windowEndAbsMs = accWindow.windowEndAbsMs
        let frames = accWindow.pcm
        let commitMarginMs = appState.pipelineConfig.commitMarginMs

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
                        commitMarginMs: commitMarginMs,
                        minTokenProbability: self.appState.pipelineConfig.minTokenProbability
                    )
                    self.updateUIFromStabilizer()
                    self.trimIfNeeded()
                    self.isDecoding = false

                    if self.needsRedecode {
                        self.needsRedecode = false
                        self.tick()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isDecoding = false
                    self.logger.error("Tick decode failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Accumulate-and-Trim

    /// Trim accumulated audio at a sentence boundary in the first half of committed text,
    /// keeping enough trailing audio for Whisper to produce overlapping output with LA-2.
    private func trimIfNeeded() {
        let config = appState.pipelineConfig
        let durationMs = recordingSession.audioRecorder.accumulatedDurationMs
        guard durationMs > config.maxBufferMs else { return }

        let committed = stabilizer.state.rawCommitted
        guard !committed.isEmpty else { return }

        let words = committed.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        guard words.count > 3 else { return }

        // Find the first sentence boundary in the first half of committed text.
        // This keeps ~50%+ of audio as context for stable Whisper overlap.
        let midPoint = words.count / 2
        var sentenceBoundaryWordIndex: Int? = nil
        for i in 0...midPoint {
            let word = words[i]
            if word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?") {
                sentenceBoundaryWordIndex = i
            }
        }

        // If no sentence boundary in first half, force-trim at ~40% of committed words
        let trimWordIndex = sentenceBoundaryWordIndex ?? (words.count * 2 / 5)
        guard trimWordIndex > 0 else { return }

        // Estimate audio position proportionally
        let totalSamples = recordingSession.audioRecorder.totalSamplesRecorded
        let accTrimOffset = recordingSession.audioRecorder.currentTrimOffset
        let availableSamples = totalSamples - accTrimOffset
        let fraction = Double(trimWordIndex + 1) / Double(words.count)
        let trimSampleOffset = accTrimOffset + Int(fraction * Double(availableSamples))

        recordingSession.audioRecorder.trimAccumulated(toSampleOffset: trimSampleOffset)
        logger.info("Trimmed audio buffer at word \(trimWordIndex)/\(words.count), ~\(Int(fraction * 100))% of audio, new duration: \(self.recordingSession.audioRecorder.accumulatedDurationMs)ms")
    }

    // MARK: - UI Updates

    private func updateUIFromStabilizer() {
        let state = stabilizer.state
        var committed = state.rawCommitted
        var speculative = state.rawSpeculative

        // Apply filler word removal if enabled
        if appState.fillerWordRemoval {
            committed = fillerWordFilter.filter(committed)
            speculative = fillerWordFilter.filter(speculative)
        }

        appState.committedText = committed
        appState.speculativeText = speculative
    }

    // MARK: - Finalization

    private func finalizeRecording() async {
        appState.transitionTo(.transcribing)

        // Wait for any in-flight decode to complete
        while isDecoding {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        // Perform an authoritative decode of ALL recorded audio.
        // The incremental stabilizer can lose words when Whisper produces different
        // tokenizations across sliding window boundaries. A single decode of the
        // full audio avoids this entirely. whisper_full() internally handles long
        // audio via 30-second seek chunks, so this works for any recording length.
        let fullAudio = recordingSession.audioRecorder.getFullAudio()
        if !fullAudio.isEmpty {
            do {
                let freshTranscription = try await whisperManager.transcribeFull(frames: fullAudio)
                if !freshTranscription.isEmpty {
                    stabilizer.reset()
                    stabilizer.state.rawCommitted = freshTranscription
                    logger.info("Full-audio decode: \(freshTranscription.count) chars (\(fullAudio.count) samples)")
                }
            } catch {
                logger.error("Full-audio decode failed, falling back to stabilizer: \(error.localizedDescription)")
            }
        }

        // Finalize any remaining speculative text
        stabilizer.finalizeAll()
        updateUIFromStabilizer()

        var rawText = stabilizer.state.rawCommitted

        // Apply filler word filter if enabled
        if appState.fillerWordRemoval {
            rawText = fillerWordFilter.filter(rawText)
        }

        guard !rawText.isEmpty else {
            logger.info("Recording produced empty transcription")
            cleanup()
            appState.transitionTo(.idle)
            RecordingOverlayWindow.shared.hide()
            return
        }

        RecordingOverlayWindow.shared.hide()

        // Detect app context from frontmost app (if enabled)
        let appContext: AppCategory = appState.appContextEnabled
            ? AppContextDetector.detect(bundleIdentifier: recordingSession.frontmostApp?.bundleIdentifier)
            : .general

        let finalText = await pasteCoordinator.finalize(
            rawText: rawText,
            llmConfig: cachedLLMConfig ?? appState.llmConfig,
            targetApp: recordingSession.frontmostApp,
            appState: appState,
            customVocabulary: CustomVocabulary.load(),
            appContext: appContext,
            activePreset: AIModePreset.activePreset(),
            preferDirectInsertion: false // TODO: temporarily disabled, always use clipboard paste
        )

        // Save to history
        TranscriptionHistoryStore.shared.addRecord(TranscriptionRecord(
            rawText: stabilizer.state.rawCommitted,
            processedText: finalText != rawText ? finalText : nil,
            durationSeconds: appState.recordingDuration,
            modelName: appState.selectedModelName,
            language: appState.selectedLanguage
        ))

        cleanup()
        appState.transitionTo(.idle)
        logger.info("Pipeline complete, final text: \(finalText.prefix(80))")
    }

    // MARK: - Sound Feedback

    private func playStartSound() {
        guard appState.soundFeedback else { return }
        NSSound(named: .init("Tink"))?.play()
    }

    private func playStopSound() {
        guard appState.soundFeedback else { return }
        NSSound(named: .init("Pop"))?.play()
    }

    // MARK: - Prompt Building

    /// Build a Whisper prompt from committed text, truncating at a sentence
    /// boundary so the model gets coherent context rather than a fragment.
    private func buildPrompt(from committed: String) -> String? {
        guard !committed.isEmpty else { return nil }
        guard committed.count > appState.pipelineConfig.maxPromptChars else { return committed }

        let suffix = String(committed.suffix(appState.pipelineConfig.maxPromptChars))
        // Trim to the nearest sentence boundary
        if let dotRange = suffix.range(of: ". ", options: .literal) {
            return String(suffix[dotRange.upperBound...])
        }
        // Fall back to a word boundary
        if let spaceRange = suffix.range(of: " ", options: .literal) {
            return String(suffix[spaceRange.upperBound...])
        }
        return suffix
    }

    // MARK: - Cleanup

    private func cleanup() {
        stabilizer.reset()
        silenceDetector.reset()
        recordingSession.cleanup()
        isDecoding = false
        needsRedecode = false
        cachedLLMConfig = nil
    }
}
