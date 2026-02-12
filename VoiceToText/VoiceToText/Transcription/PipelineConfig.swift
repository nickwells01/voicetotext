import Foundation

// MARK: - Pipeline Configuration

struct PipelineConfig: Codable, Equatable {
    var sampleRate: Int = 16000
    var tickMs: Int = 250
    var windowMs: Int = 8000        // min 4000, max 12000
    var commitMarginMs: Int = 700   // range 500–900
    var maxPromptChars: Int = 1200
    var silenceMs: Int = 900
    var noSpeechThreshold: Float = 0.75
    var minTokenProbability: Float = 0.10
    var maxSessionMinutes: Int = 30

    var windowSamples: Int { sampleRate * windowMs / 1000 }
    var tickInterval: TimeInterval { Double(tickMs) / 1000.0 }
    var commitMarginSamples: Int { sampleRate * commitMarginMs / 1000 }

    // Adaptive backpressure
    var maxTickMs: Int = 500
    var minWindowMs: Int = 4000

    // Accumulate-and-trim: max accumulated audio before trimming at sentence boundary
    var maxBufferMs: Int = 12000

    // MARK: - Persistence

    static let storageKey = "pipelineConfig"

    static func load() -> PipelineConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(PipelineConfig.self, from: data) else {
            return PipelineConfig()
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: PipelineConfig.storageKey)
        }
    }
}
