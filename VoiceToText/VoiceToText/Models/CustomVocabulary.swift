import Foundation

// MARK: - Custom Vocabulary

struct CustomVocabulary: Codable, Equatable {
    var words: [String]

    init(words: [String] = []) {
        self.words = words
    }

    /// Generate a prompt suffix instructing the LLM to preserve these terms.
    var promptSuffix: String {
        guard !words.isEmpty else { return "" }
        let wordList = words.joined(separator: ", ")
        return "\n\nIMPORTANT: Preserve the following proper nouns and technical terms exactly as spelled: \(wordList)"
    }

    // MARK: - Persistence

    static func load() -> CustomVocabulary {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.customVocabulary),
              let vocab = try? JSONDecoder().decode(CustomVocabulary.self, from: data) else {
            return CustomVocabulary()
        }
        return vocab
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: StorageKey.customVocabulary)
        }
    }
}
