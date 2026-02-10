import Foundation
import KeyboardShortcuts

// MARK: - AppStorage Keys

enum StorageKey {
    static let selectedModelName = "selectedModelName"
    static let activationMode = "activationMode"
    static let triggerMethod = "triggerMethod"
    static let aiCleanupEnabled = "aiCleanupEnabled"
    static let llmConfigData = "llmConfigData"
    static let launchAtLogin = "launchAtLogin"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let fnDoubleTapInterval = "fnDoubleTapInterval"
    static let fastMode = "fastMode"
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

// MARK: - Trigger Method

enum TriggerMethod: String, CaseIterable, Identifiable {
    case fnHold = "fnHold"
    case fnDoubleTap = "fnDoubleTap"
    case keyboardShortcut = "keyboardShortcut"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fnHold: return "Hold Fn"
        case .fnDoubleTap: return "Double-Tap Fn"
        case .keyboardShortcut: return "Keyboard Shortcut"
        }
    }
}

// MARK: - Whisper Model Definition

struct WhisperModel: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let fileName: String       // q8_0 variant (primary)
    let downloadURL: URL       // q8_0 variant (primary)
    let fileSize: Int64        // q8_0 size in bytes
    let q5FileName: String     // q5 variant (fast mode)
    let q5DownloadURL: URL     // q5 variant (fast mode)
    let q5FileSize: Int64      // q5 size in bytes
    let coreMLModelURL: URL?   // URL to CoreML encoder zip (contains -encoder.mlmodelc)

    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var q5FileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: q5FileSize, countStyle: .file)
    }

    /// Whether the primary file is a distinct higher-quality variant than the fast file.
    /// When false, both point to the same file and there is no separate fast option.
    var hasFastVariant: Bool {
        fileName != q5FileName
    }

    /// Label for the primary quantization (e.g. "Q8" or "Q5")
    var primaryQuantLabel: String {
        if fileName.contains("q8_0") { return "Q8" }
        if fileName.contains("q5_0") || fileName.contains("q5_1") { return "Q5" }
        return "Model"
    }

    /// Expected directory name for the CoreML encoder alongside the .bin model file
    var coreMLEncoderName: String {
        fileName.replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc")
    }

    static let availableModels: [WhisperModel] = [
        WhisperModel(
            id: "tiny.en",
            displayName: "Tiny (Fastest)",
            fileName: "ggml-tiny.en-q8_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q8_0.bin")!,
            fileSize: 43_600_000,
            q5FileName: "ggml-tiny.en-q5_1.bin",
            q5DownloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q5_1.bin")!,
            q5FileSize: 32_200_000,
            coreMLModelURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-encoder.mlmodelc.zip")!
        ),
        WhisperModel(
            id: "base.en",
            displayName: "Small (Fast)",
            fileName: "ggml-base.en-q8_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q8_0.bin")!,
            fileSize: 81_800_000,
            q5FileName: "ggml-base.en-q5_1.bin",
            q5DownloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin")!,
            q5FileSize: 59_700_000,
            coreMLModelURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-encoder.mlmodelc.zip")!
        ),
        WhisperModel(
            id: "small.en",
            displayName: "Medium (Balanced)",
            fileName: "ggml-small.en-q8_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q8_0.bin")!,
            fileSize: 264_000_000,
            q5FileName: "ggml-small.en-q5_1.bin",
            q5DownloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q5_1.bin")!,
            q5FileSize: 190_000_000,
            coreMLModelURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-encoder.mlmodelc.zip")!
        ),
        WhisperModel(
            id: "medium.en",
            displayName: "Large (Best Quality)",
            fileName: "ggml-medium.en-q8_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en-q8_0.bin")!,
            fileSize: 823_000_000,
            q5FileName: "ggml-medium.en-q5_0.bin",
            q5DownloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en-q5_0.bin")!,
            q5FileSize: 539_000_000,
            coreMLModelURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en-encoder.mlmodelc.zip")!
        ),
        WhisperModel(
            id: "large-v3-turbo",
            displayName: "XL Turbo (Best Speed/Accuracy)",
            fileName: "ggml-large-v3-turbo-q8_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin")!,
            fileSize: 874_000_000,
            q5FileName: "ggml-large-v3-turbo-q5_0.bin",
            q5DownloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
            q5FileSize: 574_000_000,
            coreMLModelURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-encoder.mlmodelc.zip")!
        ),
        WhisperModel(
            id: "large-v3",
            displayName: "XXL (Most Accurate)",
            fileName: "ggml-large-v3-q5_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin")!,
            fileSize: 1_080_000_000,
            q5FileName: "ggml-large-v3-q5_0.bin",
            q5DownloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin")!,
            q5FileSize: 1_080_000_000,
            coreMLModelURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-encoder.mlmodelc.zip")!
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
