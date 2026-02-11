import Foundation
import AppKit
import os

/// Manages the recording lifecycle: starting/stopping audio capture, tick timer, and focus tracking.
@MainActor
final class RecordingSession {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "RecordingSession")

    let audioRecorder = AudioRecorder()
    private(set) var ringBuffer: AudioRingBuffer?
    private(set) var frontmostApp: NSRunningApplication?

    private var tickTimer: Timer?
    var onTick: (() -> Void)?

    // MARK: - Start

    func start(config: PipelineConfig, clipboardPaster: ClipboardPaster) throws {
        // Record frontmost app for paste focus restoration
        frontmostApp = clipboardPaster.recordFrontmostApp()

        // Create ring buffer for this session
        let buffer = AudioRingBuffer(capacity: config.windowSamples, sampleRate: config.sampleRate)
        ringBuffer = buffer

        try audioRecorder.startCapture(ringBuffer: buffer)

        // Start tick timer
        tickTimer = Timer.scheduledTimer(withTimeInterval: config.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onTick?()
            }
        }

        logger.info("Recording session started (tick: \(config.tickMs)ms, window: \(config.windowMs)ms)")
    }

    // MARK: - Stop

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        audioRecorder.stopCapture()
        logger.info("Recording session stopped")
    }

    // MARK: - Cancel / Cleanup

    func cleanup() {
        stop()
        ringBuffer = nil
        frontmostApp = nil
    }
}
