import Foundation
import os

/// Schedules LLM burst cleaning during recording when enough new text accumulates.
@MainActor
final class LLMBurstScheduler {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "LLMBurstScheduler")

    private var lastCleanCharCount = 0
    private let burstThreshold = 200

    /// Check if enough new committed text has accumulated and trigger LLM cleaning.
    /// Returns true if a burst clean was started.
    @discardableResult
    func maybeRunBurstClean(
        committedText: String,
        llmConfig: LLMConfig?,
        onCleanedResult: @escaping (String) -> Void
    ) -> Bool {
        guard let llmConfig, llmConfig.isEnabled && llmConfig.isValid else { return false }

        let newChars = committedText.count - lastCleanCharCount
        guard newChars > burstThreshold else { return false }

        lastCleanCharCount = committedText.count

        let postProcessor = LLMPostProcessor(config: llmConfig)
        Task {
            let cleaned = await postProcessor.processChunked(rawText: committedText)
            await MainActor.run {
                onCleanedResult(cleaned)
            }
        }

        return true
    }

    func reset() {
        lastCleanCharCount = 0
    }
}
