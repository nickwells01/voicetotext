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

    func runLLMTest() async {
        func log(_ msg: String) {
            FileHandle.standardError.write(Data("[LLMTest] \(msg)\n".utf8))
        }

        // Build LLM config from saved settings (same as PasteCoordinator)
        let llmConfig = LLMConfig.load()
        guard llmConfig.isEnabled && llmConfig.isValid else {
            log("ERROR: LLM cleanup is not enabled or config is invalid")
            log("Enable AI cleanup in Settings and configure a local or remote model")
            return
        }

        // Wait for local LLM model readiness
        if llmConfig.provider == .local {
            let manager = await LocalLLMManager.shared
            let deadline = Date().addingTimeInterval(120)
            while !manager.state.isReady && Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard manager.state.isReady else {
                log("ERROR: Local LLM model never became ready after 120s")
                return
            }
        }

        let harness = LLMCleanupTestHarness()
        _ = await harness.run(llmConfig: llmConfig)
    }

    func runTestBatch(categoryFilter: String? = nil, enableMedical: Bool = false) async {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "TestHarness")

        guard isModelReady else {
            print("[TestHarness] ERROR: no model loaded")
            logger.error("Cannot run batch test: no model loaded")
            return
        }
        print("[TestHarness] runTestBatch() starting (filter: \(categoryFilter ?? "all"), medical: \(enableMedical))")

        let harness = TranscriptionTestHarness()

        do {
            _ = try await harness.runBatch(
                whisperManager: whisperManager,
                pipelineConfig: AppState.shared.pipelineConfig,
                categoryFilter: categoryFilter,
                enableMedical: enableMedical
            )
        } catch {
            print("[TestHarness] ERROR: \(error)")
            logger.error("Batch test failed: \(error.localizedDescription)")
        }
    }

    func runMedicalABTest() async {
        func log(_ msg: String) {
            FileHandle.standardError.write(Data("[TestHarness] \(msg)\n".utf8))
        }

        guard isModelReady else {
            log("ERROR: no model loaded")
            return
        }

        let harness = TranscriptionTestHarness()
        let pipelineConfig = AppState.shared.pipelineConfig

        // Run A: baseline (no medical corrections)
        log("")
        log("╔══════════════════════════════════════════╗")
        log("║   RUN A: BASELINE (no medical mode)      ║")
        log("╚══════════════════════════════════════════╝")
        let baselineReport: BatchReport
        do {
            baselineReport = try await harness.runBatch(
                whisperManager: whisperManager,
                pipelineConfig: pipelineConfig,
                categoryFilter: "medical",
                enableMedical: false
            )
        } catch {
            log("ERROR in baseline run: \(error)")
            return
        }

        // Run B: medical mode ON
        log("")
        log("╔══════════════════════════════════════════╗")
        log("║   RUN B: MEDICAL MODE ON                 ║")
        log("╚══════════════════════════════════════════╝")
        let medicalReport: BatchReport
        do {
            medicalReport = try await harness.runBatch(
                whisperManager: whisperManager,
                pipelineConfig: pipelineConfig,
                categoryFilter: "medical",
                enableMedical: true
            )
        } catch {
            log("ERROR in medical run: \(error)")
            return
        }

        // Print A/B comparison
        log("")
        log("╔══════════════════════════════════════════════════════════════════╗")
        log("║                    A/B COMPARISON RESULTS                       ║")
        log("╚══════════════════════════════════════════════════════════════════╝")
        log("")
        log("ID                    | Baseline WER | Medical WER | Delta    | Base Recall | Med Recall | Status")
        log("--------------------- | ------------ | ----------- | -------- | ----------- | ---------- | ------")

        for i in 0..<baselineReport.results.count {
            let base = baselineReport.results[i]
            let med = medicalReport.results[i]
            let id = base.phrase.id.padding(toLength: 21, withPad: " ", startingAt: 0)
            let baseWER = String(format: "%5.1f%%", base.productionWER * 100).padding(toLength: 12, withPad: " ", startingAt: 0)
            let medWER = String(format: "%5.1f%%", med.productionWER * 100).padding(toLength: 11, withPad: " ", startingAt: 0)
            let delta = med.productionWER - base.productionWER
            let deltaStr = String(format: "%+5.1f%%", delta * 100).padding(toLength: 8, withPad: " ", startingAt: 0)
            let baseRecall = base.medicalTermRecall.map { String(format: "%5.0f%%", $0 * 100) } ?? "  n/a"
            let baseRecallCol = baseRecall.padding(toLength: 11, withPad: " ", startingAt: 0)
            let medRecall = med.medicalTermRecall.map { String(format: "%5.0f%%", $0 * 100) } ?? "  n/a"
            let medRecallCol = medRecall.padding(toLength: 10, withPad: " ", startingAt: 0)
            let improved = delta < -0.005 ? "BETTER" : (delta > 0.005 ? "WORSE" : "SAME")
            log("\(id) | \(baseWER) | \(medWER) | \(deltaStr) | \(baseRecallCol) | \(medRecallCol) | \(improved)")
        }

        log("")
        log("=== Aggregate A/B ===")
        log("Baseline: mean production WER \(String(format: "%.1f", baselineReport.meanProductionWER * 100))%, pass \(baselineReport.passCount)/\(baselineReport.results.count)")
        log("Medical:  mean production WER \(String(format: "%.1f", medicalReport.meanProductionWER * 100))%, pass \(medicalReport.passCount)/\(medicalReport.results.count)")
        let werDelta = medicalReport.meanProductionWER - baselineReport.meanProductionWER
        log("Delta:    \(String(format: "%+.1f", werDelta * 100))% mean production WER")

        let baseRecalls = baselineReport.results.compactMap(\.medicalTermRecall)
        let medRecalls = medicalReport.results.compactMap(\.medicalTermRecall)
        if !baseRecalls.isEmpty && !medRecalls.isEmpty {
            let baseMeanRecall = baseRecalls.reduce(0, +) / Double(baseRecalls.count)
            let medMeanRecall = medRecalls.reduce(0, +) / Double(medRecalls.count)
            log("Baseline recall: mean \(String(format: "%.0f", baseMeanRecall * 100))%")
            log("Medical recall:  mean \(String(format: "%.0f", medMeanRecall * 100))%")
            log("Recall delta:    \(String(format: "%+.0f", (medMeanRecall - baseMeanRecall) * 100))%")
        }
        log("=== END A/B ===")
    }
}
#endif
