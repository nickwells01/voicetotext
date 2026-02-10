import Foundation
import KeyboardShortcuts

// MARK: - AppStorage Keys

enum StorageKey {
    static let selectedModelName = "selectedModelName"
    static let activationMode = "activationMode"
    static let useFnDoubleTap = "useFnDoubleTap"
    static let aiCleanupEnabled = "aiCleanupEnabled"
    static let llmConfigData = "llmConfigData"
    static let launchAtLogin = "launchAtLogin"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let fnDoubleTapInterval = "fnDoubleTapInterval"
}

// MARK: - Activation Mode

enum ActivationMode: String, CaseIterable, Identifiable {
    case holdToTalk = "holdToTalk"
    case toggle = "toggle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .holdToTalk: return "Hold to Talk"
        case .toggle: return "Toggle (Press to Start/Stop)"
        }
    }
}

// MARK: - Whisper Model Definition

struct WhisperModel: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let fileName: String
    let downloadURL: URL
    let fileSize: Int64 // bytes

    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    static let availableModels: [WhisperModel] = [
        WhisperModel(
            id: "base.en",
            displayName: "Small (Fast)",
            fileName: "ggml-base.en.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
            fileSize: 148_000_000
        ),
        WhisperModel(
            id: "small.en",
            displayName: "Medium (Balanced)",
            fileName: "ggml-small.en.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!,
            fileSize: 488_000_000
        ),
        WhisperModel(
            id: "medium.en",
            displayName: "Large (Best Quality)",
            fileName: "ggml-medium.en.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin")!,
            fileSize: 1_533_000_000
        ),
    ]

    static func model(forId id: String) -> WhisperModel? {
        availableModels.first { $0.id == id }
    }
}

// MARK: - LLM Configuration

struct LLMConfig: Codable, Equatable {
    var apiURL: String = "https://api.openai.com"
    var apiKey: String = ""
    var modelName: String = "gpt-4o-mini"
    var isEnabled: Bool = false
    var systemPrompt: String = "Fix grammar, punctuation, and formatting. Return only the corrected text. Do not add any explanation."

    var isValid: Bool {
        !apiURL.isEmpty && !apiKey.isEmpty && !modelName.isEmpty
    }

    static func load() -> LLMConfig {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.llmConfigData),
              let config = try? JSONDecoder().decode(LLMConfig.self, from: data) else {
            return LLMConfig()
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: StorageKey.llmConfigData)
        }
    }
}

// MARK: - KeyboardShortcuts Extension

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.space, modifiers: [.control, .shift]))
}
