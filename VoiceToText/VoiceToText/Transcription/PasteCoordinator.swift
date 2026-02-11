import Foundation
import AppKit
import os

/// Coordinates the finalization and paste workflow after recording stops.
@MainActor
final class PasteCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "PasteCoordinator")

    private let clipboardPaster = ClipboardPaster()
    private let directInserter = DirectTextInserter()

    /// Finalize the recording: optional LLM post-processing, then paste to target app.
    func finalize(
        rawText: String,
        llmConfig: LLMConfig?,
        targetApp: NSRunningApplication?,
        appState: AppState,
        customVocabulary: CustomVocabulary? = nil,
        appContext: AppCategory? = nil,
        activePreset: AIModePreset? = nil,
        preferDirectInsertion: Bool = true
    ) async -> String {
        guard !rawText.isEmpty else {
            logger.info("Empty transcription, nothing to paste")
            return ""
        }

        // Optional LLM post-processing
        var finalText = rawText
        if var llmConfig, llmConfig.isEnabled && llmConfig.isValid {
            appState.transitionTo(.processing)

            // Apply active preset's system prompt if available
            if let preset = activePreset {
                llmConfig.systemPrompt = preset.systemPrompt
            }

            // Append context-aware modifier
            if let context = appContext, context != .general {
                let modifier = AppContextDetector.promptModifier(for: context)
                if !modifier.isEmpty {
                    llmConfig.systemPrompt += "\n\n" + modifier
                }
            }

            // Append custom vocabulary
            if let vocab = customVocabulary, !vocab.words.isEmpty {
                llmConfig.systemPrompt += vocab.promptSuffix
            }

            let postProcessor = LLMPostProcessor(config: llmConfig)
            finalText = await postProcessor.process(rawText: rawText)
            logger.info("LLM processed: '\(rawText.prefix(40))' → '\(finalText.prefix(40))'")
        }

        // Store for menu bar display
        appState.lastTranscription = finalText

        // Brief settle time for window server
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Try direct text insertion first (preserves clipboard)
        if preferDirectInsertion {
            let insertResult = directInserter.insert(text: finalText)
            switch insertResult {
            case .inserted:
                logger.info("Direct text insertion succeeded")
                return finalText
            case .notSupported(let reason):
                logger.info("Direct insertion not available (\(reason)), falling back to clipboard paste")
            }
        }

        // Fall back to clipboard paste
        let pasteResult = await clipboardPaster.paste(text: finalText, targetApp: targetApp)

        switch pasteResult {
        case .pasted:
            break
        case .copiedOnly(let reason):
            appState.toastMessage = "Copied to clipboard (paste manually)"
            logger.warning("Paste failed: \(reason). Text on clipboard.")
            RecordingOverlayWindow.shared.showToast("Copied — paste with ⌘V")
        }

        return finalText
    }

    func recordFrontmostApp() -> NSRunningApplication? {
        clipboardPaster.recordFrontmostApp()
    }
}
