import Foundation

// MARK: - Pipeline Configuration

struct PipelineConfig {
    var sampleRate: Int = 16000
    var tickMs: Int = 250
    var windowMs: Int = 8000        // min 4000, max 12000
    var commitMarginMs: Int = 700   // range 500–900
    var maxPromptChars: Int = 1200
    var silenceMs: Int = 900
    var noSpeechThreshold: Float = 0.75
    var maxSessionMinutes: Int = 30

    var windowSamples: Int { sampleRate * windowMs / 1000 }
    var tickInterval: TimeInterval { Double(tickMs) / 1000.0 }
    var commitMarginSamples: Int { sampleRate * commitMarginMs / 1000 }

    // Adaptive backpressure
    var maxTickMs: Int = 500
    var minWindowMs: Int = 4000
}
