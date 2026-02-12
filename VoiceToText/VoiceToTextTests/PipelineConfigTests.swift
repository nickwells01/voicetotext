import XCTest
@testable import VoiceToText

final class PipelineConfigTests: XCTestCase {

    // MARK: - Default Values

    func testDefaultValues() {
        let config = PipelineConfig()

        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.tickMs, 250)
        XCTAssertEqual(config.windowMs, 8000)
        XCTAssertEqual(config.commitMarginMs, 700)
        XCTAssertEqual(config.maxPromptChars, 1200)
        XCTAssertEqual(config.silenceMs, 900)
        XCTAssertEqual(config.noSpeechThreshold, 0.75, accuracy: 1e-6)
        XCTAssertEqual(config.minTokenProbability, 0.10, accuracy: 1e-6)
        XCTAssertEqual(config.maxSessionMinutes, 30)
        XCTAssertEqual(config.maxTickMs, 500)
        XCTAssertEqual(config.minWindowMs, 4000)
        XCTAssertEqual(config.maxBufferMs, 12000)
    }

    // MARK: - Computed Properties

    func testWindowSamplesComputed() {
        let config = PipelineConfig()
        // 16000 * 8000 / 1000 = 128000
        XCTAssertEqual(config.windowSamples, 128000)
    }

    func testTickIntervalComputed() {
        let config = PipelineConfig()
        // 250 / 1000.0 = 0.25
        XCTAssertEqual(config.tickInterval, 0.25, accuracy: 1e-9)
    }

    func testCommitMarginSamplesComputed() {
        let config = PipelineConfig()
        // 16000 * 700 / 1000 = 11200
        XCTAssertEqual(config.commitMarginSamples, 11200)
    }

    func testComputedPropertiesWithCustomValues() {
        var config = PipelineConfig()
        config.sampleRate = 44100
        config.windowMs = 5000
        config.tickMs = 100
        config.commitMarginMs = 500

        // windowSamples: 44100 * 5000 / 1000 = 220500
        XCTAssertEqual(config.windowSamples, 220500)
        // tickInterval: 100 / 1000.0 = 0.1
        XCTAssertEqual(config.tickInterval, 0.1, accuracy: 1e-9)
        // commitMarginSamples: 44100 * 500 / 1000 = 22050
        XCTAssertEqual(config.commitMarginSamples, 22050)
    }

    // MARK: - Codable Round Trip

    func testCodableRoundTrip() {
        let original = PipelineConfig()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try! encoder.encode(original)
        let decoded = try! decoder.decode(PipelineConfig.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    func testNonDefaultCodableRoundTrip() {
        var config = PipelineConfig()
        config.sampleRate = 44100
        config.tickMs = 100
        config.windowMs = 6000
        config.commitMarginMs = 500
        config.maxPromptChars = 2000
        config.silenceMs = 1200
        config.noSpeechThreshold = 0.5
        config.minTokenProbability = 0.2
        config.maxSessionMinutes = 60
        config.maxTickMs = 800
        config.minWindowMs = 3000
        config.maxBufferMs = 15000

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try! encoder.encode(config)
        let decoded = try! decoder.decode(PipelineConfig.self, from: data)

        XCTAssertEqual(config, decoded)

        // Verify a few fields to confirm actual values survived the round trip
        XCTAssertEqual(decoded.sampleRate, 44100)
        XCTAssertEqual(decoded.noSpeechThreshold, 0.5, accuracy: 1e-6)
        XCTAssertEqual(decoded.maxBufferMs, 15000)
    }
}
