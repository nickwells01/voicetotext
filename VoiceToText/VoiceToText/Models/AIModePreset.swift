import Foundation

// MARK: - AI Mode Preset

struct AIModePreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var systemPrompt: String
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, systemPrompt: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.isBuiltIn = isBuiltIn
    }

    // MARK: - Built-in Presets

    static let grammarFix = AIModePreset(
        name: "Grammar Fix",
        systemPrompt: "Fix grammar, punctuation, and formatting. Return only the corrected text. Do not add any explanation.",
        isBuiltIn: true
    )

    static let emailPro = AIModePreset(
        name: "Email Pro",
        systemPrompt: "Rewrite as a professional email. Use formal tone, proper greeting and sign-off. Return only the email text.",
        isBuiltIn: true
    )

    static let bulletPoints = AIModePreset(
        name: "Bullet Points",
        systemPrompt: "Convert the spoken text into clear, concise bullet points. Return only the bullet points, one per line starting with '-'.",
        isBuiltIn: true
    )

    static let codeDocs = AIModePreset(
        name: "Code Docs",
        systemPrompt: "Format as a code documentation comment. Use clear technical language. Return only the formatted comment.",
        isBuiltIn: true
    )

    static let translate = AIModePreset(
        name: "Translate",
        systemPrompt: "Translate the text to English. If already in English, fix grammar. Return only the translated text.",
        isBuiltIn: true
    )

    static let casual = AIModePreset(
        name: "Casual",
        systemPrompt: "Clean up the text to sound natural and casual. Fix grammar but keep the conversational tone. Return only the cleaned text.",
        isBuiltIn: true
    )

    static let builtInPresets: [AIModePreset] = [
        grammarFix, emailPro, bulletPoints, codeDocs, translate, casual
    ]

    // MARK: - Persistence

    static func loadCustomPresets() -> [AIModePreset] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.aiModePresets),
              let presets = try? JSONDecoder().decode([AIModePreset].self, from: data) else {
            return []
        }
        return presets
    }

    static func saveCustomPresets(_ presets: [AIModePreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: StorageKey.aiModePresets)
        }
    }

    static func allPresets() -> [AIModePreset] {
        builtInPresets + loadCustomPresets()
    }

    static func activePreset() -> AIModePreset? {
        guard let idString = UserDefaults.standard.string(forKey: StorageKey.activeAIModePresetId),
              let id = UUID(uuidString: idString) else {
            return nil
        }
        return allPresets().first { $0.id == id }
    }

    static func setActivePreset(_ preset: AIModePreset?) {
        UserDefaults.standard.set(preset?.id.uuidString, forKey: StorageKey.activeAIModePresetId)
    }
}
