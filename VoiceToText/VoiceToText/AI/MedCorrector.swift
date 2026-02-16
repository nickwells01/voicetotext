import Foundation
import os

/// Post-ASR spell corrector for medical terminology.
/// Runs on each chunk's raw words after Whisper decode, before the stabilizer.
/// Conservative and fast (< 5ms target per chunk).
final class MedCorrector {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "MedCorrector")

    let index: MedicalTermIndex

    /// Maximum number of single-word corrections per chunk to prevent over-correction.
    static let maxCorrectionsPerChunk = 3

    struct Correction {
        let original: String
        let corrected: String
        let editDistance: Int
    }

    init(index: MedicalTermIndex) {
        self.index = index
    }

    /// Correct words in a raw word array from Whisper output.
    /// Returns the corrected word array and a list of corrections applied.
    func correctWords(_ words: [String]) -> (words: [String], corrections: [Correction]) {
        guard !words.isEmpty else { return (words, []) }

        var result = words
        var corrections: [Correction] = []
        var correctionCount = 0

        var i = 0
        while i < result.count {
            let word = result[i]
            let lower = word.lowercased().trimmingCharacters(in: .punctuationCharacters)

            // Skip short words, words with digits, already-known terms
            guard lower.count >= 6 else { i += 1; continue }
            guard !lower.contains(where: { $0.isNumber }) else { i += 1; continue }
            guard !index.termSet.contains(lower) else { i += 1; continue }
            guard !MedicalTermIndex.stopwords.contains(lower) else { i += 1; continue }

            // Check multi-word medical terms starting at this position
            if let multiWord = index.checkMultiWord(words: result, startIndex: i) {
                // Multi-word match found — the words are already correct as a phrase
                let wordCount = multiWord.split(separator: " ").count
                i += wordCount
                continue
            }

            // Fuzzy single-word correction
            guard correctionCount < Self.maxCorrectionsPerChunk else { i += 1; continue }

            if let match = index.fuzzyMatch(word) {
                let corrected = applyCapitalization(from: word, to: match.term)
                let correction = Correction(
                    original: word,
                    corrected: corrected,
                    editDistance: match.editDistance
                )
                corrections.append(correction)
                result[i] = preservePunctuation(original: word, corrected: corrected)
                correctionCount += 1
                logger.notice("MedCorrector: \"\(word)\" -> \"\(result[i])\" (edit distance: \(match.editDistance))")
            }

            i += 1
        }

        return (result, corrections)
    }

    // MARK: - Capitalization Preservation

    /// Apply the capitalization pattern of the original word to the corrected word.
    private func applyCapitalization(from original: String, to corrected: String) -> String {
        let origChars = Array(original)

        // All uppercase -> all uppercase
        if origChars.allSatisfy({ $0.isUppercase || !$0.isLetter }) {
            return corrected.uppercased()
        }

        // Title case (first char uppercase, rest lowercase)
        if let first = origChars.first, first.isUppercase {
            return corrected.prefix(1).uppercased() + corrected.dropFirst()
        }

        // Default: keep corrected as-is (lowercase from index)
        return corrected
    }

    /// Preserve leading/trailing punctuation from the original word on the corrected word.
    private func preservePunctuation(original: String, corrected: String) -> String {
        var leading = ""
        var trailing = ""

        // Extract leading punctuation
        for ch in original {
            if ch.isPunctuation || ch == "\"" || ch == "'" {
                leading.append(ch)
            } else {
                break
            }
        }

        // Extract trailing punctuation
        for ch in original.reversed() {
            if ch.isPunctuation || ch == "\"" || ch == "'" {
                trailing = String(ch) + trailing
            } else {
                break
            }
        }

        return leading + corrected + trailing
    }
}
