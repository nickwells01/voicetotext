import Foundation
import os
import MLXLLM
import MLXLMCommon
import MLX

// MARK: - Local LLM Manager

@MainActor
final class LocalLLMManager: ObservableObject {
    static let shared = LocalLLMManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "LocalLLMManager")

    // MARK: - State

    enum ModelState: Equatable {
        case unloaded
        case downloading(progress: Double)
        case loading
        case ready
        case error(String)
        case unloading

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Published var state: ModelState = .unloaded
    @Published var currentModelId: String?

    private var modelContainer: ModelContainer?
    private var session: ChatSession?
    private var systemPrompt: String = ""

    private init() {
        // Let MLX manage GPU cache with generous limit.
        // Too-small values (e.g. 20MB) force constant re-allocation and destroy performance.
        MLX.GPU.set(cacheLimit: 1024 * 1024 * 1024)
    }

    // MARK: - Model Lifecycle

    func prepareModel(modelId: String, systemPrompt: String) async {
        // Skip if already loaded with the same model
        if currentModelId == modelId, state.isReady {
            self.systemPrompt = systemPrompt
            resetSession(systemPrompt: systemPrompt)
            logger.info("Model \(modelId) already loaded, reset session")
            return
        }

        // Unload previous model if any
        if currentModelId != nil {
            await unloadModel()
        }

        self.systemPrompt = systemPrompt
        self.currentModelId = modelId

        state = .downloading(progress: 0)
        logger.info("Preparing local LLM: \(modelId)")

        do {
            let modelConfiguration = ModelConfiguration(id: modelId)

            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfiguration
            ) { progress in
                Task { @MainActor in
                    self.state = .downloading(progress: progress.fractionCompleted)
                }
            }

            state = .loading
            self.modelContainer = container
            let params = GenerateParameters(maxTokens: 2048, temperature: 0.1)
            self.session = ChatSession(container, instructions: systemPrompt, generateParameters: params)

            state = .ready
            logger.info("Local LLM ready: \(modelId)")
        } catch {
            state = .error(error.localizedDescription)
            logger.error("Failed to prepare local LLM: \(error.localizedDescription)")
        }
    }

    // MARK: - Inference

    func process(rawText: String) async -> String {
        guard state.isReady, let session else {
            logger.warning("Local LLM not ready, returning raw text")
            return rawText
        }

        // Cap generation at ~2x input token estimate (1 token ≈ 4 chars) + headroom
        let estimatedInputTokens = max(rawText.count / 4, 20)
        session.generateParameters.maxTokens = estimatedInputTokens * 2

        do {
            let result = try await session.respond(to: rawText)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                logger.warning("Local LLM returned empty response, returning raw text")
                return rawText
            }
            logger.info("Local LLM processed text (\(rawText.count) -> \(trimmed.count) chars)")
            return trimmed
        } catch {
            logger.error("Local LLM inference failed: \(error.localizedDescription). Returning raw text.")
            return rawText
        }
    }

    // MARK: - Session Management

    func resetSession(systemPrompt: String) {
        guard let session else { return }
        self.systemPrompt = systemPrompt
        session.instructions = systemPrompt
        Task { await session.clear() }
    }

    // MARK: - Unload

    func unloadModel() async {
        state = .unloading
        session = nil
        modelContainer = nil
        currentModelId = nil
        state = .unloaded
        logger.info("Local LLM unloaded")
    }

    // MARK: - Test

    func testInference() async -> Bool {
        guard state.isReady, let session else { return false }

        do {
            let result = try await session.respond(to: "Hello")
            let success = !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Reset session after test to clear context
            resetSession(systemPrompt: systemPrompt)
            logger.info("Local LLM test inference \(success ? "succeeded" : "failed")")
            return success
        } catch {
            logger.error("Local LLM test inference failed: \(error.localizedDescription)")
            return false
        }
    }
}
