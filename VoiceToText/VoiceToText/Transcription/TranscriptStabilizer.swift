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

    var fullRawText: String {
        rawSpeculative.isEmpty ? rawCommitted
            : rawCommitted + (rawCommitted.isEmpty ? "" : " ") + rawSpeculative
    }

    var committedWordCount: Int {
        rawCommitted.split(separator: " ", omittingEmptySubsequences: true).count
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
    /// Low-probability tokens (< `minTokenProbability`) are filtered before LA-2
    /// comparison to prevent hallucinations from poisoning agreement.
    @discardableResult
    func update(decodeResult: DecodeResult,
                windowEndAbsMs: Int,
                commitMarginMs: Int,
                minTokenProbability: Float = 0.10) -> TranscriptState {

        // 1. Build word list from token data, truncating at first low-probability token.
        //    Falls back to segment text when token data is unavailable.
        let (decodeRaw, decodeNorm) = extractWordsFromResult(decodeResult, minProbability: minTokenProbability)

        guard !decodeRaw.isEmpty else { return state }

        // 2. LA-2: compare current decode directly with previous decode.
        // By comparing raw decode outputs (not reconstructed "full" arrays),
        // we avoid structural mismatches caused by different overlap-detection paths.
        let commonPrefixLen = longestCommonPrefix(state.previousDecodeNormalizedWords, decodeNorm)

        // 3. Determine how many decode words correspond to already-committed text.
        // This tells us where "new" content starts in the decode.
        let committedRaw = state.rawCommitted
            .split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        let committedNorm = committedRaw.map { normalizeWord($0) }

        let committedInDecode: Int
        if committedNorm.isEmpty {
            committedInDecode = 0
        } else {
            let prefixMatch = longestCommonPrefix(committedNorm, decodeNorm)
            if prefixMatch >= committedNorm.count {
                // Decode reproduces all committed words, new content starts after
                committedInDecode = committedNorm.count
            } else {
                // Decode doesn't fully match committed (e.g., after trim).
                // Find how many words at the start of the decode overlap with
                // the tail of committed text (suffix-prefix overlap).
                var tailOverlap = 0
                let maxCheck = min(committedNorm.count, decodeNorm.count)
                for len in stride(from: maxCheck, through: 1, by: -1) {
                    if Array(committedNorm.suffix(len)) == Array(decodeNorm.prefix(len)) {
                        tailOverlap = len
                        break
                    }
                }
                committedInDecode = tailOverlap
            }
        }

        // 4. Commit newly confirmed words.
        // Words in [committedInDecode..<effectivePrefix] are agreed upon by two
        // consecutive decodes and haven't been committed yet.
        //
        // Trailing-edge margin: when the agreement extends to the very end of
        // the previous decode, hold back the last word. Whisper often inserts
        // spurious periods/artifacts at the boundary of clear speech, and LA-2
        // agrees on them because both decodes see the same partial audio.
        // Holding back 1 word prevents committing these trailing artifacts.
        let atPrevEnd = (commonPrefixLen >= state.previousDecodeRawWords.count)
        let effectivePrefix = atPrevEnd ? max(0, commonPrefixLen - 1) : commonPrefixLen

        let committedBefore = state.rawCommitted
        if effectivePrefix > committedInDecode
            && effectivePrefix <= state.previousDecodeRawWords.count {
            let newlyConfirmed = state.previousDecodeRawWords[committedInDecode..<effectivePrefix]
            let newText = newlyConfirmed.joined(separator: " ")

            if state.rawCommitted.isEmpty {
                state.rawCommitted = newText
            } else {
                state.rawCommitted += " " + newText
            }

            // Remove repeated phrases (hallucination safety net)
            // Skip O(n^2) non-consecutive scan during streaming; full scan runs in finalizeAll()
            state.rawCommitted = removeRepeatedPhrases(state.rawCommitted, minNonConsecutivePhraseLen: 7)
            state.rawCommitted = normalizeWhitespace(state.rawCommitted)
        }

        // 5. Words after effectivePrefix are speculative (includes held-back trailing word)
        let speculativeWords = decodeRaw.suffix(from: min(effectivePrefix, decodeRaw.count))
        let newSpeculative = normalizeWhitespace(speculativeWords.joined(separator: " "))
        let committedGrew = state.rawCommitted != committedBefore

        // 6. Speculative stability hold (anti-flicker)
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

        // 7. Store decode word arrays for next tick's comparison
        state.previousDecodeRawWords = decodeRaw
        state.previousDecodeNormalizedWords = decodeNorm

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

        // Strip trailing sentence fragments (1-3 words after last sentence-ending
        // punctuation). These are almost always echo artifacts from Whisper re-decoding
        // the beginning of the audio after the real content ends.
        let finalWords = state.rawCommitted.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        if let lastWord = finalWords.last,
           !lastWord.hasSuffix(".") && !lastWord.hasSuffix("!") && !lastWord.hasSuffix("?") {
            if let lastSentenceEnd = finalWords.lastIndex(where: {
                $0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?")
            }) {
                let trailingCount = finalWords.count - lastSentenceEnd - 1
                if trailingCount <= 3 {
                    state.rawCommitted = finalWords[0...lastSentenceEnd].joined(separator: " ")
                }
            }
        }

        // Clear LocalAgreement state
        state.previousDecodeRawWords = []
        state.previousDecodeNormalizedWords = []
        return state
    }

    // MARK: - Trim Notification

    /// Reset LA-2 comparison state after an audio trim.
    /// After trimming, Whisper decodes different audio context, so the previous
    /// word list is stale and would poison LA-2 agreement for many ticks.
    /// Clearing it lets the first post-trim decode establish a clean baseline.
    func notifyTrimmed() {
        state.previousDecodeRawWords = []
        state.previousDecodeNormalizedWords = []
    }

    // MARK: - Reset

    func reset() {
        state = TranscriptState()
    }

    // MARK: - Internal

    /// Extract words from a decode result using per-token probability data.
    /// BPE tokens are concatenated using Whisper's convention: a leading space
    /// in token text indicates a new word boundary, otherwise the token is a
    /// sub-word continuation. Stops at the first low-probability token or when
    /// a hallucination loop is detected (same 3+ word phrase repeated).
    /// Falls back to segment text when token data is unavailable.
    private func extractWordsFromResult(_ result: DecodeResult, minProbability: Float) -> ([String], [String]) {
        var rawWords: [String] = []
        var currentWord = ""
        var stopped = false

        for segment in result.segments {
            if stopped { break }
            guard !segment.tokens.isEmpty else {
                // Flush accumulated BPE word
                if !currentWord.isEmpty {
                    rawWords.append(currentWord)
                    currentWord = ""
                }
                // No token data — fall back to segment text
                let segWords = segment.text.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
                rawWords.append(contentsOf: segWords)
                continue
            }
            for token in segment.tokens {
                let trimmed = token.text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                // Stop at first low-probability token (likely hallucination)
                if token.probability < minProbability {
                    stopped = true
                    break
                }
                // BPE convention: leading space = new word boundary
                if token.text.hasPrefix(" ") {
                    if !currentWord.isEmpty {
                        rawWords.append(currentWord)
                        // Check for hallucination loop after each complete word
                        if detectLoop(rawWords) {
                            stopped = true
                            break
                        }
                    }
                    currentWord = trimmed
                } else {
                    // Sub-word continuation
                    currentWord += token.text
                }
            }
        }
        // Flush final accumulated word
        if !currentWord.isEmpty {
            rawWords.append(currentWord)
        }
        // Final loop check and trim if needed
        trimLoop(&rawWords)
        let normWords = rawWords.map { normalizeWord($0) }
        return (rawWords, normWords)
    }

    /// Detect if the last N words form a repeating loop (e.g., "A cup of coffee. A cup of coffee.").
    /// Returns true if a 3-5 word phrase has repeated 2+ times consecutively at the end.
    private func detectLoop(_ words: [String]) -> Bool {
        let count = words.count
        for phraseLen in 3...5 {
            guard count >= phraseLen * 2 else { continue }
            let phrase = words[(count - phraseLen)..<count].map { normalizeWord($0) }
            let prev = words[(count - phraseLen * 2)..<(count - phraseLen)].map { normalizeWord($0) }
            if phrase == prev { return true }
        }
        return false
    }

    /// Remove the trailing repeated phrase from a loop, keeping only one occurrence.
    private func trimLoop(_ words: inout [String]) {
        for phraseLen in stride(from: 5, through: 3, by: -1) {
            guard words.count >= phraseLen * 2 else { continue }
            let phrase = words[(words.count - phraseLen)..<words.count].map { normalizeWord($0) }
            let prev = words[(words.count - phraseLen * 2)..<(words.count - phraseLen)].map { normalizeWord($0) }
            if phrase == prev {
                words.removeLast(phraseLen)
                return
            }
        }
    }

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
