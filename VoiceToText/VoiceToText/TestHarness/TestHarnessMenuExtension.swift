#if DEBUG
import Foundation
import os

extension TranscriptionPipeline {
    func runTestHarness() async {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "TestHarness")

        guard isModelReady else {
            print("[TestHarness] ERROR: no model loaded")
            logger.error("Cannot run test harness: no model loaded")
            return
        }
        print("[TestHarness] runTestHarness() starting")

        let phrase: String
        if CommandLine.arguments.contains("--long") {
            phrase = "The morning sun cast golden light across the quiet valley as birds began their daily chorus. A gentle breeze carried the scent of wildflowers through the open window. She poured herself a cup of coffee and sat down at the old wooden desk. The letters from her grandmother were still stacked neatly in the drawer, each one carefully preserved in its original envelope. She picked up the first one and began to read, smiling at the familiar handwriting that brought back so many cherished memories of summers spent together by the lake."
        } else {
            phrase = TestHarnessConfig().phrase
        }
        let config = TestHarnessConfig(
            phrase: phrase,
            pipelineConfig: AppState.shared.pipelineConfig
        )

        let harness = TranscriptionTestHarness()

        do {
            _ = try await harness.run(config: config, whisperManager: whisperManager)
        } catch {
            print("[TestHarness] ERROR: \(error)")
            logger.error("Test harness failed: \(error.localizedDescription)")
        }
    }

    func runTestBatch() async {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "TestHarness")

        guard isModelReady else {
            print("[TestHarness] ERROR: no model loaded")
            logger.error("Cannot run batch test: no model loaded")
            return
        }
        print("[TestHarness] runTestBatch() starting")

        let harness = TranscriptionTestHarness()

        do {
            _ = try await harness.runBatch(
                whisperManager: whisperManager,
                pipelineConfig: AppState.shared.pipelineConfig
            )
        } catch {
            print("[TestHarness] ERROR: \(error)")
            logger.error("Batch test failed: \(error.localizedDescription)")
        }
    }
}
#endif
