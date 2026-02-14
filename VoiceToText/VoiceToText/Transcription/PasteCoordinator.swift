import Foundation
import AppKit
import os

/// Coordinates the finalization and paste workflow after recording stops.
@MainActor
final class PasteCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "PasteCoordinator")

    private let clipboardPaster = ClipboardPaster()
    private let directInserter = DirectTextInserter()

    // MARK: - Pending Paste State

    private var pendingText: String?
    private var pendingTargetApp: NSRunningApplication?
    private weak var pendingAppState: AppState?
    private var clickMonitor: Any?
    private var timeoutWork: DispatchWorkItem?

    /// How long to wait for the user to click a text field before giving up.
    private static let pendingTimeoutSeconds: TimeInterval = 30

    // MARK: - Finalize

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
        // Cancel any previous pending paste
        cancelPendingPaste()

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
        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms

        // Check if user is in an editable text field
        let hasTextField = AXIsProcessTrusted() && directInserter.hasEditableTextField()

        if !hasTextField && AXIsProcessTrusted() {
            // No text field — try clipboard paste first (works in Terminal, etc.)
            logger.info("No editable text field focused, attempting clipboard paste")
            let pasteResult = await clipboardPaster.paste(text: finalText, targetApp: targetApp)

            switch pasteResult {
            case .pasted:
                logger.info("Clipboard paste succeeded without text field")
                return finalText
            case .copiedOnly(let reason):
                // Clipboard paste didn't work either — enter pending paste mode
                logger.info("Clipboard paste failed (\(reason)), entering pending paste mode")
                startPendingPaste(text: finalText, targetApp: targetApp, appState: appState)
                return finalText
            }
        }

        // There IS a text field (or we can't detect) — paste immediately
        return await pasteImmediately(text: finalText, targetApp: targetApp, appState: appState, preferDirectInsertion: preferDirectInsertion)
    }

    // MARK: - Immediate Paste

    private func pasteImmediately(
        text: String,
        targetApp: NSRunningApplication?,
        appState: AppState,
        preferDirectInsertion: Bool
    ) async -> String {
        // Try direct text insertion first (preserves clipboard)
        if preferDirectInsertion {
            let insertResult = directInserter.insert(text: text)
            switch insertResult {
            case .inserted:
                logger.info("Direct text insertion succeeded")
                return text
            case .notSupported(let reason):
                logger.info("Direct insertion not available (\(reason)), falling back to clipboard paste")
            }
        }

        // Fall back to clipboard paste
        let pasteResult = await clipboardPaster.paste(text: text, targetApp: targetApp)

        switch pasteResult {
        case .pasted:
            break
        case .copiedOnly(let reason):
            appState.toastMessage = "Copied to clipboard (paste manually)"
            logger.warning("Paste failed: \(reason). Text on clipboard.")
            RecordingOverlayWindow.shared.showToast("Copied — paste with \u{2318}V")
        }

        return text
    }

    // MARK: - Pending Paste

    private func startPendingPaste(text: String, targetApp: NSRunningApplication?, appState: AppState) {
        pendingText = text
        pendingTargetApp = targetApp
        pendingAppState = appState

        // Show persistent toast on the overlay
        appState.toastMessage = "Click a text field to paste"
        RecordingOverlayWindow.shared.show()

        // Monitor global mouse clicks to detect when user clicks into a text field
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Brief delay for focus to settle after the click
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
                self?.attemptPendingPaste()
            }
        }

        // Timeout: after N seconds, copy to clipboard and dismiss
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.expirePendingPaste()
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pendingTimeoutSeconds, execute: work)

        logger.info("Pending paste started — waiting for text field click (timeout: \(Self.pendingTimeoutSeconds)s)")
    }

    private func attemptPendingPaste() {
        guard let text = pendingText, let appState = pendingAppState else { return }

        // Check if the user has now clicked into an editable text field
        guard directInserter.hasEditableTextField() else { return }

        logger.info("Text field detected after click — pasting pending text")

        let targetApp = pendingTargetApp
        let preferDirect = appState.preferDirectInsertion
        cancelPendingPaste()

        Task {
            _ = await pasteImmediately(text: text, targetApp: targetApp, appState: appState, preferDirectInsertion: preferDirect)
            // Brief toast confirming the paste, then hide
            RecordingOverlayWindow.shared.showToast("Pasted")
        }
    }

    private func expirePendingPaste() {
        guard let text = pendingText, let appState = pendingAppState else { return }

        logger.info("Pending paste timed out — copying to clipboard")

        // Put text on clipboard as fallback so user can manually paste
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        cancelPendingPaste()

        appState.toastMessage = nil
        RecordingOverlayWindow.shared.showToast("Copied — paste with \u{2318}V")
    }

    func cancelPendingPaste() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        timeoutWork?.cancel()
        timeoutWork = nil

        if pendingText != nil {
            pendingAppState?.toastMessage = nil
            RecordingOverlayWindow.shared.hide()
        }

        pendingText = nil
        pendingTargetApp = nil
        pendingAppState = nil
    }

    // MARK: - Helpers

    func recordFrontmostApp() -> NSRunningApplication? {
        clipboardPaster.recordFrontmostApp()
    }
}
