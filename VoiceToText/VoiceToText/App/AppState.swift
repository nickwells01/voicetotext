import SwiftUI
import Combine
import os

// MARK: - App State

enum RecordingState: Equatable {
    case idle
    case recording
    case transcribing
    case processing // LLM post-processing
    case error(String)

    var isActive: Bool {
        switch self {
        case .recording, .transcribing, .processing:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "AppState")

    // MARK: - Published State

    @Published var recordingState: RecordingState = .idle
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastTranscription: String = ""
    @Published var errorMessage: String?
    @Published var showOnboarding: Bool = false

    // MARK: - Settings (backed by UserDefaults)

    @AppStorage(StorageKey.selectedModelName) var selectedModelName: String = "base.en"
    @AppStorage(StorageKey.activationMode) var activationMode: String = ActivationMode.holdToTalk.rawValue
    @AppStorage(StorageKey.useFnDoubleTap) var useFnDoubleTap: Bool = true
    @AppStorage(StorageKey.hasCompletedOnboarding) var hasCompletedOnboarding: Bool = false
    @AppStorage(StorageKey.fnDoubleTapInterval) var fnDoubleTapInterval: Double = 0.4
    @AppStorage(StorageKey.fastMode) var fastMode: Bool = false

    // MARK: - Computed

    var currentActivationMode: ActivationMode {
        ActivationMode(rawValue: activationMode) ?? .holdToTalk
    }

    var selectedModel: WhisperModel? {
        WhisperModel.model(forId: selectedModelName)
    }

    // MARK: - Recording Timer

    private var timerCancellable: AnyCancellable?

    func startRecordingTimer() {
        recordingDuration = 0
        timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.recordingDuration += 0.1
            }
    }

    func stopRecordingTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    // MARK: - State Transitions

    func transitionTo(_ state: RecordingState) {
        logger.info("State transition: \(String(describing: self.recordingState)) → \(String(describing: state))")
        recordingState = state

        switch state {
        case .recording:
            startRecordingTimer()
            errorMessage = nil
        case .idle:
            stopRecordingTimer()
        case .error(let message):
            stopRecordingTimer()
            errorMessage = message
            logger.error("Error state: \(message)")
        default:
            break
        }
    }
}
