import Foundation

/// Removes filler words and verbal tics from transcription text using word-boundary-aware regex.
struct FillerWordFilter {

    /// Default filler words/phrases to remove.
    static let defaultFillerWords: [String] = [
        "um", "uh", "erm", "er",
        "like",
        "you know",
        "I mean",
        "basically",
        "actually",
        "literally",
        "right",
        "so", // only as sentence-initial filler
        "well", // only as sentence-initial filler
        "kind of",
        "sort of",
    ]

    private let patterns: [NSRegularExpression]

    /// Initialize with a list of filler words/phrases.
    init(fillerWords: [String] = FillerWordFilter.defaultFillerWords) {
        self.patterns = fillerWords.compactMap { word in
            // Use word boundaries. For multi-word phrases, match as-is.
            // Case-insensitive. Only match whole words, not substrings.
            let escaped = NSRegularExpression.escapedPattern(for: word)
            // Match the filler word at word boundaries, optionally followed by a comma
            let pattern = "\\b\(escaped)\\b,?\\s*"
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    /// Remove filler words from text.
    func filter(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // Clean up double spaces and trim
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fix sentence capitalization after removal (capitalize first char after ". ")
        return result
    }
}
