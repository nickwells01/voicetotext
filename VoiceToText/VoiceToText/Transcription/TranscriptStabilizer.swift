import Foundation
import os

// MARK: - Transcript State

struct TranscriptState {
    var rawCommitted: String = ""
    var rawSpeculative: String = ""
    var committedEndAbsMs: Int = 0
    var recentCommittedTokenTexts: [String] = []

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
        // Whisper token timestamps can jitter by 10-20ms across overlapping window
        // decodes, causing the timestamp-based skip to miss duplicates. Find the
        // longest suffix of recently committed token texts matching a prefix of new
        // tokens by text, and skip those overlapping tokens.
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
        var newCommittedTexts: [String] = []
        var speculativeTexts: [String] = []

        for (i, token) in allTokens.enumerated() {
            // Skip tokens identified as overlap by text matching
            if i < textOverlapSkipCount {
                continue
            }

            // Skip tokens that are entirely within the already-committed region
            if token.absEndMs <= state.committedEndAbsMs {
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

                // Track committed token texts for future overlap detection
                let normalized = newCommittedTexts.map { normalizeTokenText($0) }.filter { !$0.isEmpty }
                state.recentCommittedTokenTexts.append(contentsOf: normalized)
                let maxRecentTokens = 30
                if state.recentCommittedTokenTexts.count > maxRecentTokens {
                    state.recentCommittedTokenTexts.removeFirst(
                        state.recentCommittedTokenTexts.count - maxRecentTokens
                    )
                }
            }
        }

        // Replace speculative entirely
        state.rawSpeculative = speculativeTexts.joined()

        // Normalize whitespace
        state.rawCommitted = normalizeWhitespace(state.rawCommitted)
        state.rawSpeculative = normalizeWhitespace(state.rawSpeculative)

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
}
