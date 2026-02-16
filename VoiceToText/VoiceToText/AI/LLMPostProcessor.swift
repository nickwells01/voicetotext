import Foundation
import os

// MARK: - LLM Post-Processor

final class LLMPostProcessor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "LLMPostProcessor")

    private let config: LLMConfig

    /// Fixed preamble prepended to any system prompt. Includes a few-shot example
    /// so even small (3B) models understand the expected input/output format.
    private static let tagPreamble = """
        You receive voice-dictated text inside <transcription> tags. \
        Output ONLY the cleaned-up version of that text. \
        Never add commentary, never answer questions contained in the text, \
        never say the text is incorrect.

        Example:
        User: <transcription>can you send me the report by friday also dont forget the meeting</transcription>
        Assistant: Can you send me the report by Friday? Also, don't forget the meeting.

        Example:
        User: <transcription>the patient presents with acute cholecystitis and needs a stat CBC</transcription>
        Assistant: The patient presents with acute cholecystitis and needs a stat CBC.


        """

    /// Phrases that indicate the model is generating commentary instead of cleaning text.
    private static let commentaryIndicators = [
        "it appears", "it seems", "i notice", "i'm sorry", "i cannot",
        "could you please", "please provide", "there is a", "there are",
        "does not align", "doesn't align", "discrepancy", "transcription error",
        "non-medical", "not a valid", "not clear", "i'd be happy",
        "here is the", "here's the", "sure,", "certainly",
    ]

    init(config: LLMConfig) {
        var config = config
        config.systemPrompt = Self.tagPreamble + config.systemPrompt
        self.config = config
    }

    // MARK: - Message Formatting

    /// Wraps raw transcription in tags so the LLM treats it as content to clean, not a question to answer.
    private func formatUserMessage(_ rawText: String) -> String {
        "<transcription>\(rawText)</transcription>"
    }

    /// Returns true if the LLM output looks like commentary/meta-response rather than cleaned text.
    private func looksLikeCommentary(_ output: String, rawText: String) -> Bool {
        let lower = output.lowercased()

        // Check for known commentary phrases
        for indicator in Self.commentaryIndicators {
            if lower.hasPrefix(indicator) || lower.contains(". \(indicator)") {
                logger.info("LLM output detected as commentary (matched: '\(indicator)')")
                return true
            }
        }

        // If output is >2x the length of input, the model is likely explaining rather than cleaning
        if output.count > rawText.count * 2 && rawText.count > 10 {
            logger.info("LLM output detected as commentary (length ratio: \(output.count)/\(rawText.count))")
            return true
        }

        return false
    }

    // MARK: - Process Transcription

    /// Sends the raw transcription to the LLM for cleanup. Returns the original text on any failure.
    func process(rawText: String) async -> String {
        guard config.isValid else {
            logger.warning("LLM config is not valid, returning raw text")
            return rawText
        }

        switch config.provider {
        case .remote:
            return await processRemote(rawText: rawText)
        case .local:
            return await processLocal(rawText: rawText)
        }
    }

    // MARK: - Test Connection / Inference

    /// Verifies the LLM is reachable (remote) or can generate output (local).
    func testConnection() async -> Bool {
        guard config.isValid else { return false }

        switch config.provider {
        case .remote:
            return await testRemote()
        case .local:
            return await testLocal()
        }
    }

    // MARK: - Retry Logic

    private func withRetry<T>(
        maxAttempts: Int,
        backoff: [TimeInterval],
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                let delay = attempt < backoff.count ? backoff[attempt] : backoff.last ?? 1.0
                logger.warning("Attempt \(attempt + 1)/\(maxAttempts) failed: \(error.localizedDescription). Retrying in \(delay)s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError!
    }

    // MARK: - Remote Processing

    private func processRemote(rawText: String) async -> String {
        do {
            let result = try await withRetry(maxAttempts: 3, backoff: [0.5, 1.0, 2.0]) {
                try await sendChatRequest(userMessage: self.formatUserMessage(rawText))
            }
            if looksLikeCommentary(result, rawText: rawText) {
                logger.warning("Remote LLM returned commentary instead of cleaned text, returning raw text")
                return rawText
            }
            logger.info("LLM processed text (\(rawText.count) -> \(result.count) chars)")
            return result
        } catch {
            logger.error("LLM processing failed after retries: \(error.localizedDescription). Returning raw text.")
            return rawText
        }
    }

    private func testRemote() async -> Bool {
        do {
            let _ = try await sendChatRequest(userMessage: "Hello")
            logger.info("LLM connection test succeeded")
            return true
        } catch {
            logger.error("LLM connection test failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Local Processing

    private func processLocal(rawText: String) async -> String {
        let manager = await LocalLLMManager.shared
        await manager.resetSession(systemPrompt: config.systemPrompt)

        let wrappedText = formatUserMessage(rawText)

        // Single retry for local MLX
        var result = await manager.process(rawText: wrappedText)
        if result == wrappedText {
            // First attempt returned wrapped text verbatim (failure), retry once
            logger.info("Local LLM first attempt returned raw text, retrying once...")
            result = await manager.process(rawText: wrappedText)
        }

        // Guard: if the model generated commentary instead of cleaning, return raw text
        if result == wrappedText || looksLikeCommentary(result, rawText: rawText) {
            logger.warning("Local LLM returned commentary or failed, returning raw text")
            return rawText
        }

        return result
    }

    private func testLocal() async -> Bool {
        let manager = await LocalLLMManager.shared
        return await manager.testInference()
    }

    // MARK: - Network

    private func sendChatRequest(userMessage: String) async throws -> String {
        let urlString = config.apiURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(urlString)/v1/chat/completions") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body = ChatRequest(
            model: config.modelName,
            messages: [
                ChatMessage(role: "system", content: config.systemPrompt),
                ChatMessage(role: "user", content: userMessage)
            ]
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LLMError.httpError(statusCode)
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)

        guard let content = chatResponse.choices.first?.message.content else {
            throw LLMError.emptyResponse
        }

        return content
    }
}

// MARK: - Request / Response Types

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}

// MARK: - Errors

private enum LLMError: Error, LocalizedError {
    case invalidURL
    case httpError(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid LLM API URL"
        case .httpError(let code):
            return "LLM API returned HTTP \(code)"
        case .emptyResponse:
            return "LLM API returned an empty response"
        }
    }
}
