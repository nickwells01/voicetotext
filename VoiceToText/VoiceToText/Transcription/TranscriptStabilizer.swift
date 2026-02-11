import Foundation
import os

// MARK: - Transcript State

struct TranscriptState {
    var rawCommitted: String = ""
    var rawSpeculative: String = ""
    var committedEndAbsMs: Int = 0
    var cleanedCommitted: String?

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
                commitMarginMs: Int) -> TranscriptState {

        let commitHorizonAbsMs = windowEndAbsMs - commitMarginMs

        // Flatten all tokens from all segments with absolute timing
        var allTokens: [(text: String, absStartMs: Int, absEndMs: Int)] = []

        for segment in decodeResult.segments {
            if segment.tokens.isEmpty {
                // Segment-level fallback when no token-level timestamps available
                let absStart = segment.startTimeMs + decodeResult.windowStartAbsMs
                let absEnd = segment.endTimeMs + decodeResult.windowStartAbsMs
                allTokens.append((
                    text: segment.text,
                    absStartMs: absStart,
                    absEndMs: absEnd
                ))
            } else {
                for token in segment.tokens {
                    let absStart = token.startTimeMs + decodeResult.windowStartAbsMs
                    let absEnd = token.endTimeMs + decodeResult.windowStartAbsMs
                    allTokens.append((
                        text: token.text,
                        absStartMs: absStart,
                        absEndMs: absEnd
                    ))
                }
            }
        }

        // Partition into committed and speculative
        var newCommittedTexts: [String] = []
        var speculativeTexts: [String] = []

        for token in allTokens {
            if token.absEndMs <= commitHorizonAbsMs && token.absStartMs >= state.committedEndAbsMs {
                newCommittedTexts.append(token.text)
                if token.absEndMs > state.committedEndAbsMs {
                    state.committedEndAbsMs = token.absEndMs
                }
            } else if token.absEndMs > commitHorizonAbsMs {
                speculativeTexts.append(token.text)
            }
        }

        // Append new committed tokens
        if !newCommittedTexts.isEmpty {
            let newText = newCommittedTexts.joined().trimmingCharacters(in: .whitespaces)
            if !newText.isEmpty {
                let previousCommitted = state.rawCommitted
                if state.rawCommitted.isEmpty {
                    state.rawCommitted = newText
                } else {
                    state.rawCommitted += " " + newText
                }
                // Guard: committed text should never shrink
                if state.rawCommitted.count < previousCommitted.count {
                    logger.warning("Committed text would shrink from \(previousCommitted.count) to \(self.state.rawCommitted.count) chars, keeping previous")
                    state.rawCommitted = previousCommitted
                }
            }
        }

        // Replace speculative entirely
        state.rawSpeculative = speculativeTexts.joined().trimmingCharacters(in: .whitespaces)

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

    private func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
