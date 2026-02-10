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
    }

    // MARK: - Stop Capture

    func stopCapture() -> [Float] {
        guard isRecording else {
            logger.warning("stopCapture called while not recording")
            return []
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false

        let samples = accumulatedSamples
        accumulatedSamples.removeAll()

        logger.info("Audio capture stopped, collected \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / Self.targetSampleRate))s)")
        return samples
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
