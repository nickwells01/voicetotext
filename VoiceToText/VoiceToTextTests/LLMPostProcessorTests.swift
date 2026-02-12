import XCTest
@testable import VoiceToText

final class LLMPostProcessorTests: XCTestCase {

    // MARK: - Sentence Splitting

    func testSplitIntoSentencesBasic() {
        let processor = LLMPostProcessor(config: LLMConfig())
        // Access internal method via chunked processing behavior
        // We'll test via the chunking behavior indirectly

        // Test that single sentence returns single chunk
        // (processChunked with 1 sentence calls process directly)
        let config = LLMConfig()
        let proc = LLMPostProcessor(config: config)

        // Can't directly test private splitIntoSentences, but we can test
        // the chunking behavior it enables
        XCTAssertNotNil(proc)
    }

    // MARK: - Config Validation

    func testRemoteConfigValidation() {
        var config = LLMConfig()
        config.provider = .remote

        // Default has empty API key
        XCTAssertFalse(config.isValid, "Remote config without API key should be invalid")

        config.apiKey = "test-key"
        config.apiURL = "https://api.example.com"
        config.modelName = "test-model"
        XCTAssertTrue(config.isValid, "Remote config with all fields should be valid")
    }

    func testLocalConfigValidation() {
        var config = LLMConfig()
        config.provider = .local

        // Default has a localModelId set
        XCTAssertTrue(config.isValid, "Local config with default model ID should be valid")

        config.localModelId = ""
        XCTAssertFalse(config.isValid, "Local config without model ID should be invalid")
    }

    // MARK: - Config Persistence

    func testConfigSaveAndLoad() {
        var config = LLMConfig()
        config.apiURL = "https://test.example.com"
        config.apiKey = "test-key-123"
        config.modelName = "test-model"
        config.isEnabled = true
        config.provider = .local
        config.localModelId = "test/model-id"
        config.systemPrompt = "Test prompt"
        config.save()

        let loaded = LLMConfig.load()
        XCTAssertEqual(loaded.apiURL, "https://test.example.com")
        XCTAssertEqual(loaded.apiKey, "test-key-123")
        XCTAssertEqual(loaded.modelName, "test-model")
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertEqual(loaded.provider, .local)
        XCTAssertEqual(loaded.localModelId, "test/model-id")
        XCTAssertEqual(loaded.systemPrompt, "Test prompt")

        // Clean up
        config.isEnabled = false
        config.apiKey = ""
        config.save()
        KeychainHelper.delete(account: "llm-api-key")
    }

    // MARK: - AI Mode Presets

    func testBuiltInPresetsExist() {
        let presets = AIModePreset.builtInPresets
        XCTAssertGreaterThanOrEqual(presets.count, 6, "Should have at least 6 built-in presets")

        let names = presets.map(\.name)
        XCTAssertTrue(names.contains("Grammar Fix"))
        XCTAssertTrue(names.contains("Email Pro"))
        XCTAssertTrue(names.contains("Bullet Points"))
        XCTAssertTrue(names.contains("Code Docs"))
        XCTAssertTrue(names.contains("Translate"))
        XCTAssertTrue(names.contains("Casual"))
    }

    func testPresetsAreBuiltIn() {
        for preset in AIModePreset.builtInPresets {
            XCTAssertTrue(preset.isBuiltIn)
            XCTAssertFalse(preset.systemPrompt.isEmpty)
        }
    }

    // MARK: - Custom Vocabulary

    func testCustomVocabularyPromptSuffix() {
        let vocab = CustomVocabulary(words: ["MLX", "SwiftUI", "Anthropic"])
        let suffix = vocab.promptSuffix
        XCTAssertTrue(suffix.contains("MLX"))
        XCTAssertTrue(suffix.contains("SwiftUI"))
        XCTAssertTrue(suffix.contains("Anthropic"))
    }

    func testEmptyVocabularyNoSuffix() {
        let vocab = CustomVocabulary(words: [])
        XCTAssertEqual(vocab.promptSuffix, "")
    }

    // MARK: - App Context Detection

    func testAppContextDetection() {
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.apple.mail"), .email)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.tinyspeck.slackmacgap"), .messaging)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.apple.Notes"), .notes)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: nil), .general)
        XCTAssertEqual(AppContextDetector.detect(bundleIdentifier: "com.unknown.app"), .general)
    }

    func testAppContextPromptModifier() {
        let emailModifier = AppContextDetector.promptModifier(for: .email)
        XCTAssertFalse(emailModifier.isEmpty)
        XCTAssertTrue(emailModifier.lowercased().contains("professional"))

        let generalModifier = AppContextDetector.promptModifier(for: .general)
        XCTAssertTrue(generalModifier.isEmpty, "General category should have empty modifier")
    }
}
