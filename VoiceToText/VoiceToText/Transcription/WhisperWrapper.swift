import Foundation
import whisper

// MARK: - Segment

struct Segment: Equatable {
    let startTime: Int
    let endTime: Int
    let text: String
}

// MARK: - Transcription Segment (Token-Level)

struct TranscriptionToken {
    let text: String
    let startTimeMs: Int
    let endTimeMs: Int
    let probability: Float
}

struct TranscriptionSegment {
    let text: String
    let startTimeMs: Int
    let endTimeMs: Int
    let tokens: [TranscriptionToken]
}

// MARK: - Sampling Strategy

enum WhisperSamplingStrategy: UInt32 {
    case greedy = 0
    case beamSearch
}

// MARK: - WhisperParams

@dynamicMemberLookup
class WhisperParams {
    internal var whisperParams: whisper_full_params
    private var _language: UnsafeMutablePointer<CChar>?

    init(strategy: WhisperSamplingStrategy = .greedy) {
        self.whisperParams = whisper_full_default_params(
            whisper_sampling_strategy(rawValue: strategy.rawValue)
        )
        // Default to English
        let pointer = strdup("en")!
        self._language = pointer
        self.whisperParams.language = UnsafePointer(pointer)
    }

    deinit {
        if let _language {
            free(_language)
        }
    }

    subscript<T>(dynamicMember keyPath: WritableKeyPath<whisper_full_params, T>) -> T {
        get { whisperParams[keyPath: keyPath] }
        set { whisperParams[keyPath: keyPath] = newValue }
    }

    var language: WhisperLanguage {
        get {
            guard let lang = whisperParams.language else { return .english }
            return WhisperLanguage(rawValue: String(cString: lang)) ?? .english
        }
        set {
            let pointer = strdup(newValue.rawValue)!
            if let _language {
                free(_language)
            }
            self._language = pointer
            whisperParams.language = UnsafePointer(pointer)
        }
    }
}

// MARK: - WhisperLanguage

enum WhisperLanguage: String {
    case auto = "auto"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case portuguese = "pt"
    case italian = "it"
    case dutch = "nl"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"
    case turkish = "tr"
    case polish = "pl"
    case swedish = "sv"
    case danish = "da"
    case norwegian = "no"
    case finnish = "fi"
    case czech = "cs"

    var displayName: String {
        switch self {
        case .auto: return "Auto-Detect"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .portuguese: return "Portuguese"
        case .italian: return "Italian"
        case .dutch: return "Dutch"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .turkish: return "Turkish"
        case .polish: return "Polish"
        case .swedish: return "Swedish"
        case .danish: return "Danish"
        case .norwegian: return "Norwegian"
        case .finnish: return "Finnish"
        case .czech: return "Czech"
        }
    }

    var code: String { rawValue }

    static let allLanguages: [WhisperLanguage] = [
        .english, .auto,
        .spanish, .french, .german, .chinese, .japanese, .korean,
        .portuguese, .italian, .dutch, .russian, .arabic, .hindi,
        .turkish, .polish, .swedish, .danish, .norwegian, .finnish, .czech
    ]

    static func from(code: String) -> WhisperLanguage {
        WhisperLanguage(rawValue: code) ?? .english
    }
}

// MARK: - WhisperError

enum WhisperError: Error {
    case invalidFrames
    case instanceBusy
    case initFailed
}

// MARK: - Whisper

class Whisper {
    private let whisperContext: OpaquePointer
    var params: WhisperParams
    private var inProgress = false

    init?(fromFileURL fileURL: URL, withParams params: WhisperParams = WhisperParams(), useGPU: Bool = true) {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        guard let ctx = fileURL.path.withCString({ whisper_init_from_file_with_params($0, cparams) }) else {
            return nil
        }
        self.whisperContext = ctx
        self.params = params
    }

    deinit {
        whisper_free(whisperContext)
    }

    func transcribe(audioFrames: [Float]) async throws -> [Segment] {
        guard !inProgress else { throw WhisperError.instanceBusy }
        guard !audioFrames.isEmpty else { throw WhisperError.invalidFrames }

        inProgress = true
        defer { inProgress = false }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                whisper_full(self.whisperContext, self.params.whisperParams, audioFrames, Int32(audioFrames.count))

                let segmentCount = whisper_full_n_segments(self.whisperContext)
                var segments: [Segment] = []
                segments.reserveCapacity(Int(segmentCount))

                for index in 0..<segmentCount {
                    guard let text = whisper_full_get_segment_text(self.whisperContext, index) else { continue }
                    let startTime = whisper_full_get_segment_t0(self.whisperContext, index)
                    let endTime = whisper_full_get_segment_t1(self.whisperContext, index)

                    segments.append(Segment(
                        startTime: Int(startTime) * 10,
                        endTime: Int(endTime) * 10,
                        text: String(cString: text)
                    ))
                }

                continuation.resume(returning: segments)
            }
        }
    }

    /// Transcribe with token-level data for sliding window pipeline.
    func transcribeWithTokens(audioFrames: [Float]) async throws -> [TranscriptionSegment] {
        guard !inProgress else { throw WhisperError.instanceBusy }
        guard !audioFrames.isEmpty else { throw WhisperError.invalidFrames }

        inProgress = true
        defer { inProgress = false }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                whisper_full(self.whisperContext, self.params.whisperParams, audioFrames, Int32(audioFrames.count))

                let segmentCount = whisper_full_n_segments(self.whisperContext)
                var segments: [TranscriptionSegment] = []
                segments.reserveCapacity(Int(segmentCount))

                for segIdx in 0..<segmentCount {
                    guard let segText = whisper_full_get_segment_text(self.whisperContext, segIdx) else { continue }
                    let segStart = Int(whisper_full_get_segment_t0(self.whisperContext, segIdx)) * 10  // centiseconds → ms
                    let segEnd = Int(whisper_full_get_segment_t1(self.whisperContext, segIdx)) * 10

                    // Extract token-level data
                    let tokenCount = whisper_full_n_tokens(self.whisperContext, segIdx)
                    var tokens: [TranscriptionToken] = []
                    tokens.reserveCapacity(Int(tokenCount))

                    for tokIdx in 0..<tokenCount {
                        let tokenData = whisper_full_get_token_data(self.whisperContext, segIdx, tokIdx)
                        guard let tokenTextPtr = whisper_full_get_token_text(self.whisperContext, segIdx, tokIdx) else { continue }
                        let tokenText = String(cString: tokenTextPtr)

                        // Skip special tokens (empty or whitespace-only after trimming)
                        let trimmed = tokenText.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty || trimmed.hasPrefix("[") || trimmed.hasPrefix("<|") { continue }

                        let tokStartMs = Int(tokenData.t0) * 10
                        let tokEndMs = Int(tokenData.t1) * 10

                        tokens.append(TranscriptionToken(
                            text: tokenText,
                            startTimeMs: tokStartMs,
                            endTimeMs: tokEndMs,
                            probability: tokenData.p
                        ))
                    }

                    segments.append(TranscriptionSegment(
                        text: String(cString: segText),
                        startTimeMs: segStart,
                        endTimeMs: segEnd,
                        tokens: tokens
                    ))
                }

                continuation.resume(returning: segments)
            }
        }
    }
}
