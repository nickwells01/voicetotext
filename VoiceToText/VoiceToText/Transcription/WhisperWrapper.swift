import Foundation
import whisper

// MARK: - Segment

struct Segment: Equatable {
    let startTime: Int
    let endTime: Int
    let text: String
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

    init?(fromFileURL fileURL: URL, withParams params: WhisperParams = WhisperParams()) {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
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
}
