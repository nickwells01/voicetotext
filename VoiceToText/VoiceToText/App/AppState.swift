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
    @Published var committedText: String = ""
    @Published var speculativeText: String = ""
    @Published var toastMessage: String?
    @Published var errorMessage: String?
    @Published var showOnboarding: Bool = false

    // MARK: - Computed

    var displayText: String {
        speculativeText.isEmpty ? committedText
            : committedText + (committedText.isEmpty ? "" : " ") + speculativeText
    }

    // MARK: - Settings (backed by UserDefaults)

    @AppStorage(StorageKey.selectedModelName) var selectedModelName: String = "base.en"
    @AppStorage(StorageKey.activationMode) var activationMode: String = ActivationMode.holdToTalk.rawValue
    @AppStorage(StorageKey.triggerMethod) var triggerMethod: String = TriggerMethod.fnHold.rawValue
    @AppStorage(StorageKey.hasCompletedOnboarding) var hasCompletedOnboarding: Bool = false
    @AppStorage(StorageKey.fnDoubleTapInterval) var fnDoubleTapInterval: Double = 0.4
    @AppStorage(StorageKey.fastMode) var fastMode: Bool = false

    // MARK: - Computed Settings

    var currentActivationMode: ActivationMode {
        ActivationMode(rawValue: activationMode) ?? .holdToTalk
    }

    var currentTriggerMethod: TriggerMethod {
        TriggerMethod(rawValue: triggerMethod) ?? .fnHold
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

    func resetStreamingText() {
        committedText = ""
        speculativeText = ""
        toastMessage = nil
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
            resetStreamingText()
        case .error(let message):
            stopRecordingTimer()
            errorMessage = message
            logger.error("Error state: \(message)")
        default:
            break
        }
    }
}
