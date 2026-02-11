import Foundation
import os

// MARK: - Transcript State

struct TranscriptState {
    var rawCommitted: String = ""
    var rawSpeculative: String = ""
    var committedEndAbsMs: Int = 0
    var recentCommittedTokenTexts: [String] = []
    var lastSpeculativeUpdateAbsMs: Int = 0

    var fullRawText: String {
        rawSpeculative.isEmpty ? rawCommitted
            : rawCommitted + (rawCommitted.isEmpty ? "" : " ") + rawSpeculative
    }
}

// MARK: - Transcript Stabilizer

/// Manages the commit horizon for streaming transcription.
/// Tokens whose absolute end time falls before the commit horizon are committed (locked);
/// tokens after the horizon remain speculative and may be replaced on the next decode.
final class TranscriptStabilizer {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "TranscriptStabilizer")

    var state = TranscriptState()

    // MARK: - Update

    /// Process a new decode result, committing tokens that fall before the commit horizon.
    @discardableResult
    func update(decodeResult: DecodeResult,
                windowEndAbsMs: Int,
                commitMarginMs: Int,
                minTokenProbability: Float = 0.25) -> TranscriptState {

        let commitHorizonAbsMs = windowEndAbsMs - commitMarginMs

        // Flatten all tokens from all segments with absolute timing and probability
        var allTokens: [(text: String, absStartMs: Int, absEndMs: Int, probability: Float)] = []

        for segment in decodeResult.segments {
            if segment.tokens.isEmpty {
                // Segment-level fallback when no token-level timestamps available
                let absStart = segment.startTimeMs + decodeResult.windowStartAbsMs
                let absEnd = segment.endTimeMs + decodeResult.windowStartAbsMs
                allTokens.append((
                    text: segment.text,
                    absStartMs: absStart,
                    absEndMs: absEnd,
                    probability: 1.0  // No token-level data; don't filter
                ))
            } else {
                for token in segment.tokens {
                    let absStart = token.startTimeMs + decodeResult.windowStartAbsMs
                    let absEnd = token.endTimeMs + decodeResult.windowStartAbsMs
                    allTokens.append((
                        text: token.text,
                        absStartMs: absStart,
                        absEndMs: absEnd,
                        probability: token.probability
                    ))
                }
            }
        }

        // Phase 4: Filter low-probability tokens (hallucination suppression).
        // Skip filtering when probability is 0 (no data available from Whisper).
        if minTokenProbability > 0 {
            allTokens = allTokens.filter { $0.probability == 0 || $0.probability >= minTokenProbability }
        }

        // Phase 5: Text-based overlap detection to handle timestamp jitter.
        // Exact token-level suffix-prefix match: find the longest suffix of recently
        // committed token texts matching a prefix of new tokens by text.
        var textOverlapSkipCount = 0
        if !state.recentCommittedTokenTexts.isEmpty && !allTokens.isEmpty {
            let newNormalized = allTokens.map { normalizeTokenText($0.text) }
            let recentTexts = state.recentCommittedTokenTexts
            let maxCheck = min(recentTexts.count, newNormalized.count)
            for len in stride(from: maxCheck, through: 1, by: -1) {
                let suffix = Array(recentTexts.suffix(len))
                let prefix = Array(newNormalized.prefix(len))
                if suffix == prefix {
                    textOverlapSkipCount = len
                    break
                }
            }
        }

        // Partition into committed and speculative.
        let committedBefore = state.rawCommitted
        var newCommittedTexts: [String] = []
        var speculativeTexts: [String] = []

        for (i, token) in allTokens.enumerated() {
            // Skip tokens identified as overlap by text matching
            if i < textOverlapSkipCount {
                continue
            }

            // Skip tokens within the already-committed region (30ms jitter tolerance
            // covers Whisper's 10-20ms timestamp jitter across overlapping windows)
            if token.absEndMs <= state.committedEndAbsMs + 30 {
                continue
            }

            if token.absEndMs <= commitHorizonAbsMs {
                newCommittedTexts.append(token.text)
                state.committedEndAbsMs = token.absEndMs
            } else {
                speculativeTexts.append(token.text)
            }
        }

        // Append new committed tokens
        if !newCommittedTexts.isEmpty {
            // Tokens carry their own leading spaces (e.g. " Hello", " world").
            // Join without separator to preserve natural spacing.
            let newText = newCommittedTexts.joined()
            if !newText.isEmpty {
                let previousCommitted = state.rawCommitted
                // Tokens typically have leading spaces; only add a space separator
                // if the new text doesn't already start with whitespace.
                if state.rawCommitted.isEmpty {
                    state.rawCommitted = newText
                } else if newText.first?.isWhitespace == true {
                    state.rawCommitted += newText
                } else {
                    state.rawCommitted += " " + newText
                }
                // Guard: committed text should never shrink
                if state.rawCommitted.count < previousCommitted.count {
                    logger.warning("Committed text would shrink from \(previousCommitted.count) to \(self.state.rawCommitted.count) chars, keeping previous")
                    state.rawCommitted = previousCommitted
                }

                // Remove repeated phrases (consecutive and non-consecutive) that
                // slipped through overlap detection
                state.rawCommitted = removeRepeatedPhrases(state.rawCommitted)

                // Track committed token texts for future overlap detection
                let normalized = newCommittedTexts.map { normalizeTokenText($0) }.filter { !$0.isEmpty }
                state.recentCommittedTokenTexts.append(contentsOf: normalized)
                let maxRecentTokens = 80
                if state.recentCommittedTokenTexts.count > maxRecentTokens {
                    state.recentCommittedTokenTexts.removeFirst(
                        state.recentCommittedTokenTexts.count - maxRecentTokens
                    )
                }
            }
        }

        // Normalize committed whitespace before speculative hold check
        state.rawCommitted = normalizeWhitespace(state.rawCommitted)

        // Compute new speculative text (normalized)
        let newSpeculative = normalizeWhitespace(speculativeTexts.joined())
        let committedGrew = state.rawCommitted != committedBefore

        // Speculative stability hold: suppress non-additive speculative changes
        // to reduce visual flicker. Allow updates when committed grew or first
        // adding speculative text. Hold disruptive changes until timer expires.
        if committedGrew || state.rawSpeculative.isEmpty {
            state.rawSpeculative = newSpeculative
            state.lastSpeculativeUpdateAbsMs = windowEndAbsMs
        } else {
            let elapsed = windowEndAbsMs - state.lastSpeculativeUpdateAbsMs
            let isAdditive = !newSpeculative.isEmpty && (
                newSpeculative.contains(state.rawSpeculative)
                || state.rawSpeculative.contains(newSpeculative))
            // Allow additive changes immediately; hold disruptive changes and
            // clearing for up to 500ms to absorb decode-to-decode jitter.
            if isAdditive || elapsed >= 500 {
                state.rawSpeculative = newSpeculative
                state.lastSpeculativeUpdateAbsMs = windowEndAbsMs
            }
            // else: keep old speculative text (suppress flicker)
        }

        return state
    }

    // MARK: - Finalize

    /// Commit everything with margin=0 (used when recording stops).
    @discardableResult
    func finalizeAll() -> TranscriptState {
        if !state.rawSpeculative.isEmpty {
            if state.rawCommitted.isEmpty {
                state.rawCommitted = state.rawSpeculative
            } else {
                state.rawCommitted += " " + state.rawSpeculative
            }
            state.rawSpeculative = ""
        }
        state.rawCommitted = removeRepeatedPhrases(state.rawCommitted)
        state.rawCommitted = normalizeWhitespace(state.rawCommitted)
        return state
    }

    // MARK: - Reset

    func reset() {
        state = TranscriptState()
    }

    // MARK: - Internal

    private func normalizeTokenText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split text into normalized content words (lowercased, punctuation-stripped, non-empty).
    /// Handles Whisper retokenization by working from natural text rather than token boundaries.
    private func normalizeWords(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0).lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Remove repeated word phrases from text — both consecutive and non-consecutive.
    /// Catches stabilizer artifacts like "jumps over the lazy jumps over the lazy dog"
    /// where the same phrase appears twice due to overlapping window re-decoding.
    private func removeRepeatedPhrases(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }

        // Pass 1: Remove non-consecutive repeated phrases (2-6 words).
        // Only remove the LATER occurrence (preserves the first, which was committed first).
        // Minimum 2 words prevents false removal of single common words like "the".
        for phraseLen in stride(from: 6, through: 2, by: -1) {
            var i = 0
            while i + phraseLen <= words.count {
                let phrase = words[i..<(i + phraseLen)].map { $0.lowercased() }
                // Search for this same phrase later in the text
                var j = i + 1
                while j + phraseLen <= words.count {
                    let candidate = words[j..<(j + phraseLen)].map { $0.lowercased() }
                    if phrase == candidate {
                        words.removeSubrange(j..<(j + phraseLen))
                        // Also remove any preceding punctuation-only words that
                        // were separating the two occurrences (e.g. "sells . She" → "sells")
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
                if phrase.map({ $0.lowercased() }) == next.map({ $0.lowercased() }) {
                    words.removeSubrange((i + phraseLen)..<(i + phraseLen * 2))
                } else {
                    i += 1
                }
            }
        }

        // Pass 3: Remove punctuation + single-word artifacts.
        // When a standalone punctuation mark is followed by a word that already
        // appeared within the last 3 words before the punctuation, it's a
        // sentence-boundary hallucination. E.g. "She sells . She" → "She sells".
        var k = 0
        while k + 1 < words.count {
            let punctWord = words[k]
            if punctWord.allSatisfy({ $0.isPunctuation || $0 == "-" }) && k > 0 && k + 1 < words.count {
                let after = words[k + 1].lowercased()
                let lookback = min(3, k)
                var found = false
                for b in 1...lookback {
                    if words[k - b].lowercased() == after {
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
