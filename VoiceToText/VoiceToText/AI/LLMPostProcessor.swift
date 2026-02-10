import Foundation
import os

// MARK: - LLM Post-Processor

final class LLMPostProcessor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "LLMPostProcessor")

    private let config: LLMConfig

    init(config: LLMConfig) {
        self.config = config
    }

    // MARK: - Process Transcription

    /// Sends the raw transcription to the LLM for cleanup. Returns the original text on any failure.
    func process(rawText: String) async -> String {
        guard config.isValid else {
            logger.warning("LLM config is not valid, returning raw text")
            return rawText
        }

        do {
            let result = try await sendChatRequest(userMessage: rawText)
            logger.info("LLM processed text (\(rawText.count) -> \(result.count) chars)")
            return result
        } catch {
            logger.error("LLM processing failed: \(error.localizedDescription). Returning raw text.")
            return rawText
        }
    }

    // MARK: - Test Connection

    /// Sends a simple test message to verify the LLM endpoint is reachable and configured correctly.
    func testConnection() async -> Bool {
        guard config.isValid else { return false }

        do {
            let _ = try await sendChatRequest(userMessage: "Hello")
            logger.info("LLM connection test succeeded")
            return true
        } catch {
            logger.error("LLM connection test failed: \(error.localizedDescription)")
            return false
        }
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
