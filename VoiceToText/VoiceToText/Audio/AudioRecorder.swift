@preconcurrency import AVFoundation
import os

// MARK: - Audio Recorder Errors

enum AudioRecorderError: Error, LocalizedError {
    case engineStartFailed(Error)
    case noInputDevice
    case converterCreationFailed
    case notRecording

    var errorDescription: String? {
        switch self {
        case .engineStartFailed(let underlying):
            return "Failed to start audio engine: \(underlying.localizedDescription)"
        case .noInputDevice:
            return "No audio input device available"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .notRecording:
            return "Not currently recording"
        }
    }
}

// MARK: - Audio Recorder

@MainActor
final class AudioRecorder {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "AudioRecorder")

    private let audioEngine = AVAudioEngine()
    private var accumulatedSamples: [Float] = []
    private var isRecording = false

    // Target format: 16kHz mono Float32
    private static let targetSampleRate: Double = 16000.0
    private static let targetChannelCount: AVAudioChannelCount = 1

    private static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: targetSampleRate,
                      channels: targetChannelCount,
                      interleaved: false)!
    }

    // MARK: - Streaming Chunk Support

    /// Called every ~3 seconds during recording with new audio samples (includes 200ms overlap from previous chunk)
    var onChunkReady: (([Float]) -> Void)?

    /// How many samples have been emitted to chunks so far
    private var lastChunkEndIndex: Int = 0

    /// Timer for periodic chunk emission
    private var chunkTimer: Timer?

    /// Chunk interval in seconds
    private static let chunkIntervalSeconds: Double = 3.0

    /// Overlap in samples (200ms at 16kHz = 3200 samples)
    private static let overlapSamples: Int = Int(targetSampleRate * 0.2)

    // MARK: - Start Capture

    func startCapture() throws {
        guard !isRecording else {
            logger.warning("startCapture called while already recording")
            return
        }

        let inputNode = audioEngine.inputNode

        // Use the hardware's native format for the tap (safest for Bluetooth/AirPods)
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Hardware format: \(hardwareFormat.sampleRate)Hz, \(hardwareFormat.channelCount)ch")

        guard hardwareFormat.sampleRate > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        let targetFormat = Self.targetFormat

        // Create converter from hardware format to 16kHz mono Float32
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }

        accumulatedSamples.removeAll()
        lastChunkEndIndex = 0
        isRecording = true

        // Install tap using the hardware's native format
        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) {
            [weak self] buffer, _ in
            self?.processBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            try audioEngine.start()
            logger.info("Audio capture started")
        } catch {
            inputNode.removeTap(onBus: 0)
            isRecording = false
            throw AudioRecorderError.engineStartFailed(error)
        }

        // Set up chunk emission timer if streaming is enabled
        if onChunkReady != nil {
            chunkTimer = Timer.scheduledTimer(withTimeInterval: Self.chunkIntervalSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.emitChunk()
                }
            }
        }
    }

    // MARK: - Stop Capture

    func stopCapture() -> [Float] {
        guard isRecording else {
            logger.warning("stopCapture called while not recording")
            return []
        }

        chunkTimer?.invalidate()
        chunkTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false

        let samples = accumulatedSamples
        accumulatedSamples.removeAll()
        lastChunkEndIndex = 0

        logger.info("Audio capture stopped, collected \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / Self.targetSampleRate))s)")
        return samples
    }

    /// Stop capture and return only the unprocessed tail samples (after the last emitted chunk).
    /// Used in streaming mode so only the remaining audio needs transcription.
    func stopCaptureAndGetTail() -> [Float] {
        guard isRecording else {
            logger.warning("stopCaptureAndGetTail called while not recording")
            return []
        }

        chunkTimer?.invalidate()
        chunkTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false

        // Include overlap from the last emitted chunk so words at the boundary aren't lost
        let tailStart = max(0, lastChunkEndIndex - Self.overlapSamples)
        let tail: [Float]
        if tailStart < accumulatedSamples.count {
            tail = Array(accumulatedSamples[tailStart...])
        } else {
            tail = []
        }

        let totalDuration = Double(accumulatedSamples.count) / Self.targetSampleRate
        let tailDuration = Double(tail.count) / Self.targetSampleRate
        logger.info("Audio capture stopped (streaming). Total: \(String(format: "%.2f", totalDuration))s, Tail: \(String(format: "%.2f", tailDuration))s")

        accumulatedSamples.removeAll()
        lastChunkEndIndex = 0

        return tail
    }

    // MARK: - Chunk Emission

    private func emitChunk() {
        guard isRecording, let onChunkReady else { return }

        let currentCount = accumulatedSamples.count
        guard currentCount > lastChunkEndIndex else { return }

        // Include overlap from previous chunk for word boundary accuracy
        let overlapStart = max(0, lastChunkEndIndex - Self.overlapSamples)
        let chunk = Array(accumulatedSamples[overlapStart..<currentCount])

        lastChunkEndIndex = currentCount

        let chunkDuration = Double(chunk.count) / Self.targetSampleRate
        logger.info("Emitting chunk: \(chunk.count) samples (\(String(format: "%.2f", chunkDuration))s)")

        onChunkReady(chunk)
    }

    // MARK: - Buffer Processing

    private nonisolated func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Calculate output frame capacity based on sample rate ratio
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                   frameCapacity: outputFrameCount) else {
            return
        }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return buffer
        }

        if let error {
            // Log but don't crash; occasional conversion errors are recoverable
            let msg = error.localizedDescription
            Task { @MainActor [logger] in
                logger.error("Audio conversion error: \(msg)")
            }
            return
        }

        guard let channelData = outputBuffer.floatChannelData,
              outputBuffer.frameLength > 0 else {
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channelData[0],
                                                 count: Int(outputBuffer.frameLength)))

        Task { @MainActor [weak self] in
            self?.accumulatedSamples.append(contentsOf: samples)
        }
    }
}
