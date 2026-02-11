#if DEBUG
import Foundation
import os

extension TranscriptionPipeline {
    func runTestHarness() async {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "TestHarness")

        guard isModelReady else {
            logger.error("Cannot run test harness: no model loaded")
            return
        }

        let config = TestHarnessConfig(
            pipelineConfig: AppState.shared.pipelineConfig
        )

        let harness = TranscriptionTestHarness()

        do {
            _ = try await harness.run(config: config, whisperManager: whisperManager)
        } catch {
            logger.error("Test harness failed: \(error.localizedDescription)")
        }
    }
}
#endif
