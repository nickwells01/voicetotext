import XCTest
@testable import VoiceToText

final class AudioRingBufferTests: XCTestCase {

    // MARK: - Basic Write/Read

    func testWriteAndReadExactCapacity() {
        let buffer = AudioRingBuffer(capacity: 100, sampleRate: 16000)
        let samples = (0..<100).map { Float($0) }
        buffer.append(samples: samples)

        let window = buffer.getWindow()
        XCTAssertEqual(window.pcm.count, 100)
        XCTAssertEqual(window.pcm, samples)
        XCTAssertEqual(buffer.totalSamplesWritten, 100)
    }

    func testWriteLessThanCapacity() {
        let buffer = AudioRingBuffer(capacity: 200, sampleRate: 16000)
        let samples = [Float](repeating: 0.5, count: 50)
        buffer.append(samples: samples)

        let window = buffer.getWindow()
        XCTAssertEqual(window.pcm.count, 50)
        XCTAssertEqual(buffer.totalSamplesWritten, 50)
    }

    // MARK: - Overflow / Wrap

    func testOverflowWrapsCorrectly() {
        let buffer = AudioRingBuffer(capacity: 100, sampleRate: 16000)

        // Write 150 samples (overflow by 50)
        let firstBatch = (0..<100).map { Float($0) }
        buffer.append(samples: firstBatch)

        let secondBatch = (100..<150).map { Float($0) }
        buffer.append(samples: secondBatch)

        let window = buffer.getWindow()
        // Should contain samples 50-149 (the latest 100)
        XCTAssertEqual(window.pcm.count, 100)
        XCTAssertEqual(window.pcm.first, 50.0)
        XCTAssertEqual(window.pcm.last, 149.0)
        XCTAssertEqual(buffer.totalSamplesWritten, 150)
    }

    func testMultipleOverflows() {
        let buffer = AudioRingBuffer(capacity: 10, sampleRate: 16000)

        // Write 3 batches of 10
        for batch in 0..<3 {
            let samples = (0..<10).map { Float(batch * 10 + $0) }
            buffer.append(samples: samples)
        }

        let window = buffer.getWindow()
        // Should contain 20-29
        XCTAssertEqual(window.pcm.count, 10)
        XCTAssertEqual(window.pcm, (20..<30).map { Float($0) })
        XCTAssertEqual(buffer.totalSamplesWritten, 30)
    }

    // MARK: - Absolute Timestamp Mapping

    func testWindowAbsoluteTimestamps() {
        let buffer = AudioRingBuffer(capacity: 16000, sampleRate: 16000) // 1s capacity
        let samples = [Float](repeating: 0, count: 16000)

        buffer.append(samples: samples)

        let window = buffer.getWindow()
        XCTAssertEqual(window.windowStartAbsMs, 0)
        XCTAssertEqual(window.windowEndAbsMs, 1000) // 1 second
    }

    func testWindowTimestampsAfterOverflow() {
        let buffer = AudioRingBuffer(capacity: 16000, sampleRate: 16000) // 1s capacity

        // Write 2.5 seconds of audio
        let samples = [Float](repeating: 0, count: 40000) // 2.5s
        buffer.append(samples: samples)

        let window = buffer.getWindow()
        // Window should be the last 1 second: 1.5s to 2.5s
        XCTAssertEqual(window.windowStartAbsMs, 1500)
        XCTAssertEqual(window.windowEndAbsMs, 2500)
        XCTAssertEqual(window.pcm.count, 16000)
    }

    func testSampleIndexToAbsMs() {
        let buffer = AudioRingBuffer(capacity: 100, sampleRate: 16000)
        XCTAssertEqual(buffer.sampleIndexToAbsMs(0), 0)
        XCTAssertEqual(buffer.sampleIndexToAbsMs(16000), 1000)
        XCTAssertEqual(buffer.sampleIndexToAbsMs(8000), 500)
    }

    // MARK: - Empty Buffer

    func testEmptyBufferReturnsEmptyWindow() {
        let buffer = AudioRingBuffer(capacity: 100, sampleRate: 16000)
        let window = buffer.getWindow()
        XCTAssertTrue(window.pcm.isEmpty)
        XCTAssertEqual(window.windowStartAbsMs, 0)
        XCTAssertEqual(window.windowEndAbsMs, 0)
    }

    // MARK: - Reset

    func testResetClearsState() {
        let buffer = AudioRingBuffer(capacity: 100, sampleRate: 16000)
        buffer.append(samples: [Float](repeating: 1.0, count: 50))

        XCTAssertEqual(buffer.totalSamplesWritten, 50)

        buffer.reset()

        XCTAssertEqual(buffer.totalSamplesWritten, 0)
        let window = buffer.getWindow()
        XCTAssertTrue(window.pcm.isEmpty)
    }
}
