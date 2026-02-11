import Foundation
import os

// MARK: - Transcript State

struct TranscriptState {
    // Core state (consumed by pipeline & UI)
    var rawCommitted: String = ""
    var rawSpeculative: String = ""

    // Speculative flicker hold
    var lastSpeculativeUpdateAbsMs: Int = 0

    // LocalAgreement-2 state
    var previousDecodeRawWords: [String] = []
    var previousDecodeNormalizedWords: [String] = []
    var committedWordCount: Int = 0

    var fullRawText: String {
        rawSpeculative.isEmpty ? rawCommitted
            : rawCommitted + (rawCommitted.isEmpty ? "" : " ") + rawSpeculative
    }
}

// MARK: - Transcript Stabilizer

/// Manages the commit horizon for streaming transcription using LocalAgreement-2.
/// If 2 consecutive decodes agree on a word prefix, that prefix is confirmed.
/// No token timestamps are used in commit decisions.
final class TranscriptStabilizer {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "TranscriptStabilizer")

    var state = TranscriptState()

    // MARK: - Update

    /// Process a new decode result using LocalAgreement-2.
    /// `commitMarginMs` and `minTokenProbability` are accepted for API compatibility but unused.
    @discardableResult
    func update(decodeResult: DecodeResult,
                windowEndAbsMs: Int,
                commitMarginMs: Int,
                minTokenProbability: Float = 0.25) -> TranscriptState {

        // 1. Join all segment texts into full decode text
        let fullText = decodeResult.segments.map { $0.text }.joined()

        // 2. Split decode output into raw words (preserve casing) and normalized words
        let decodeRaw = fullText.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        let decodeNorm = decodeRaw.map { normalizeWord($0) }

        guard !decodeRaw.isEmpty else { return state }

        // 3. Reconstruct full transcript word arrays.
        // Whisper's prompted decode may output either (a) the full text from the
        // beginning of the window, or (b) just continuation after the prompt.
        // Normalize to a consistent "full text" by detecting overlap with committed.
        let committedRaw = state.rawCommitted
            .split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        let committedNorm = committedRaw.map { normalizeWord($0) }

        let fullRawWords: [String]
        let fullNormWords: [String]

        if committedNorm.isEmpty {
            // Nothing committed yet — decode is the full text
            fullRawWords = decodeRaw
            fullNormWords = decodeNorm
        } else {
            // Check if decode starts by reproducing committed text (full re-transcription)
            let prefixMatch = longestCommonPrefix(committedNorm, decodeNorm)
            if prefixMatch >= committedNorm.count {
                // Decode contains all committed words — use decode as full text
                fullRawWords = decodeRaw
                fullNormWords = decodeNorm
            } else if prefixMatch > 0 {
                // Partial prefix match — Whisper re-transcribed from beginning but diverged.
                // Use decode as the full text (commit logic will handle the divergence)
                fullRawWords = decodeRaw
                fullNormWords = decodeNorm
            } else {
                // No prefix match — decode is a continuation.
                // Check if decode starts with words that overlap the end of committed
                // (Whisper may replay a few committed words for context).
                var suffixOverlap = 0
                let maxCheck = min(committedNorm.count, decodeNorm.count)
                for len in stride(from: maxCheck, through: 2, by: -1) {
                    if Array(committedNorm.suffix(len)) == Array(decodeNorm.prefix(len)) {
                        suffixOverlap = len
                        break
                    }
                }
                let newRaw = Array(decodeRaw.dropFirst(suffixOverlap))
                let newNorm = Array(decodeNorm.dropFirst(suffixOverlap))
                fullRawWords = committedRaw + newRaw
                fullNormWords = committedNorm + newNorm
            }
        }

        // 4. LocalAgreement-2: compare full words with previous tick
        let commonPrefixLen = longestCommonPrefix(state.previousDecodeNormalizedWords, fullNormWords)

        // 5. Words in [committedWordCount..<commonPrefixLen] are newly confirmed
        let committedBefore = state.rawCommitted
        if commonPrefixLen > state.committedWordCount
            && commonPrefixLen <= state.previousDecodeRawWords.count {
            let newlyConfirmed = state.previousDecodeRawWords[state.committedWordCount..<commonPrefixLen]
            let newText = newlyConfirmed.joined(separator: " ")

            if state.rawCommitted.isEmpty {
                state.rawCommitted = newText
            } else {
                state.rawCommitted += " " + newText
            }

            // Remove repeated phrases (hallucination safety net)
            state.rawCommitted = removeRepeatedPhrases(state.rawCommitted)
            state.rawCommitted = normalizeWhitespace(state.rawCommitted)

            state.committedWordCount = commonPrefixLen
        }

        // 6. Words after commonPrefixLen are speculative
        let speculativeWords = fullRawWords.suffix(from: min(commonPrefixLen, fullRawWords.count))
        let newSpeculative = normalizeWhitespace(speculativeWords.joined(separator: " "))
        let committedGrew = state.rawCommitted != committedBefore

        // 7. Speculative stability hold (same anti-flicker logic)
        if committedGrew || state.rawSpeculative.isEmpty {
            state.rawSpeculative = newSpeculative
            state.lastSpeculativeUpdateAbsMs = windowEndAbsMs
        } else {
            let elapsed = windowEndAbsMs - state.lastSpeculativeUpdateAbsMs
            let isAdditive = !newSpeculative.isEmpty && (
                newSpeculative.contains(state.rawSpeculative)
                || state.rawSpeculative.contains(newSpeculative))
            if isAdditive || elapsed >= 500 {
                state.rawSpeculative = newSpeculative
                state.lastSpeculativeUpdateAbsMs = windowEndAbsMs
            }
        }

        // 8. Store full word arrays for next tick's comparison
        state.previousDecodeRawWords = fullRawWords
        state.previousDecodeNormalizedWords = fullNormWords

        return state
    }

    // MARK: - Finalize

    /// Commit everything (used when recording stops).
    @discardableResult
    func finalizeAll() -> TranscriptState {
        if !state.rawSpeculative.isEmpty {
            // Skip speculative text if it's already present in committed text
            // (Whisper often echoes the last few committed words as speculative)
            let specNorm = state.rawSpeculative.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespaces)
            let commitNorm = state.rawCommitted.lowercased()

            if specNorm.isEmpty || commitNorm.contains(specNorm) {
                // Echo — discard
            } else if state.rawCommitted.isEmpty {
                state.rawCommitted = state.rawSpeculative
            } else {
                state.rawCommitted += " " + state.rawSpeculative
            }
            state.rawSpeculative = ""
        }
        state.rawCommitted = removeRepeatedPhrases(state.rawCommitted, minNonConsecutivePhraseLen: 3)
        state.rawCommitted = normalizeWhitespace(state.rawCommitted)
        // Clear LocalAgreement state
        state.previousDecodeRawWords = []
        state.previousDecodeNormalizedWords = []
        return state
    }

    // MARK: - Reset

    func reset() {
        state = TranscriptState()
    }

    // MARK: - Internal

    /// Normalize a word for comparison: lowercase, strip edge punctuation.
    private func normalizeWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Find the length of the longest common prefix between two word arrays.
    private func longestCommonPrefix(_ a: [String], _ b: [String]) -> Int {
        let limit = min(a.count, b.count)
        for i in 0..<limit {
            if a[i] != b[i] {
                return i
            }
        }
        return limit
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove repeated word phrases from text — both consecutive and non-consecutive.
    /// Catches stabilizer artifacts like "jumps over the lazy jumps over the lazy dog"
    /// where the same phrase appears twice due to overlapping window re-decoding.
    private func removeRepeatedPhrases(_ text: String, minNonConsecutivePhraseLen: Int = 2) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }

        // Pass 1: Remove non-consecutive repeated phrases.
        // Only remove the LATER occurrence (preserves the first, which was committed first).
        // Compare using normalizeWord (lowercase + strip edge punctuation) so that
        // "seashells." matches "seashells" across decode boundaries.
        for phraseLen in stride(from: 6, through: minNonConsecutivePhraseLen, by: -1) {
            var i = 0
            while i + phraseLen <= words.count {
                let phrase = words[i..<(i + phraseLen)].map { normalizeWord($0) }
                // Search for this same phrase later in the text
                var j = i + 1
                while j + phraseLen <= words.count {
                    let candidate = words[j..<(j + phraseLen)].map { normalizeWord($0) }
                    if phrase == candidate {
                        words.removeSubrange(j..<(j + phraseLen))
                        // Also remove any preceding punctuation-only words
                        while j > 0 && j <= words.count {
                            let prev = words[j - 1]
                            if prev.allSatisfy({ $0.isPunctuation || $0 == "-" }) {
                                words.remove(at: j - 1)
                                j -= 1
                            } else {
                                break
                            }
                        }
                    } else {
                        j += 1
                    }
                }
                i += 1
            }
        }

        // Pass 2: Remove consecutive duplicate words/short phrases (1-4 words).
        for phraseLen in stride(from: 4, through: 1, by: -1) {
            var i = 0
            while i + phraseLen * 2 - 1 < words.count {
                let phrase = Array(words[i..<(i + phraseLen)])
                let next = Array(words[(i + phraseLen)..<(i + phraseLen * 2)])
                if phrase.map({ normalizeWord($0) }) == next.map({ normalizeWord($0) }) {
                    words.removeSubrange((i + phraseLen)..<(i + phraseLen * 2))
                } else {
                    i += 1
                }
            }
        }

        // Pass 3: Remove punctuation + single-word artifacts.
        var k = 0
        while k + 1 < words.count {
            let punctWord = words[k]
            if punctWord.allSatisfy({ $0.isPunctuation || $0 == "-" }) && k > 0 && k + 1 < words.count {
                let after = normalizeWord(words[k + 1])
                let lookback = min(3, k)
                var found = false
                for b in 1...lookback {
                    if normalizeWord(words[k - b]) == after {
                        found = true
                        break
                    }
                }
                if found {
                    words.removeSubrange(k...(k + 1))
                    continue
                }
            }
            k += 1
        }

        return words.joined(separator: " ")
    }
}
