import Foundation
import os

/// Schedules LLM burst cleaning during recording when enough new text accumulates.
@MainActor
final class LLMBurstScheduler {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "LLMBurstScheduler")

    private var lastCleanCharCount = 0
    private let burstThreshold = 200

    /// Tracks the committed text length that the in-flight burst is cleaning.
    /// When a new burst finishes, we only apply its result if no *newer* committed
    /// text has arrived since (prevents stale LLM output from overwriting fresh text).
    private var inFlightSourceLength = 0
    private(set) var isRunning = false

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

        // Don't queue another burst while one is in flight
        guard !isRunning else { return false }

        lastCleanCharCount = committedText.count
        inFlightSourceLength = committedText.count
        isRunning = true

        let postProcessor = LLMPostProcessor(config: llmConfig)
        let sourceSnapshot = committedText
        Task {
            let cleaned = await postProcessor.process(rawText: sourceSnapshot)
            await MainActor.run {
                self.isRunning = false
                // Only apply the result if committed text hasn't grown significantly
                // since we started (otherwise the cleaned text is stale/partial).
                onCleanedResult(cleaned)
            }
        }

        return true
    }

    func reset() {
        lastCleanCharCount = 0
        inFlightSourceLength = 0
        isRunning = false
    }
}
