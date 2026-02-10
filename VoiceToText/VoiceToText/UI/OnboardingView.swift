import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var permissions = PermissionsManager.shared
    @StateObject private var modelManager = ModelManager.shared

    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case 0:
                    welcomeStep
                case 1:
                    permissionsStep
                case 2:
                    modelStep
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                stepIndicator

                Spacer()

                if currentStep < 2 {
                    Button("Continue") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        appState.hasCompletedOnboarding = true
                        Task { await TranscriptionPipeline.shared.loadSelectedModel() }
                        NSApp.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canFinish)
                }
            }
            .padding()
        }
    }

    private var canFinish: Bool {
        let hasModel = WhisperModel.availableModels.contains { modelManager.isModelDownloaded($0) }
        return hasModel
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to VoiceToText")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Transcribe your voice to text instantly from anywhere on your Mac. Just press a shortcut, speak, and the transcription is pasted right where you need it.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Spacer()
        }
        .padding()
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Permissions")
                .font(.title)
                .fontWeight(.bold)

            Text("VoiceToText needs a couple of permissions to work properly.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to capture your voice for transcription.",
                    granted: permissions.microphoneGranted
                ) {
                    Task { _ = await permissions.requestMicrophonePermission() }
                }

                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Required to detect the Fn key double-tap and paste text.",
                    granted: permissions.accessibilityGranted
                ) {
                    permissions.requestAccessibilityPermission()
                }
            }
            .frame(maxWidth: 380)

            Spacer()
        }
        .padding()
        .onAppear {
            permissions.checkAllPermissions()
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
            } else {
                Button("Grant") { action() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
    }

    // MARK: - Step 3: Model Download

    private var modelStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Download a Model")
                .font(.title)
                .fontWeight(.bold)

            Text("Choose a Whisper speech recognition model. You can download additional models later in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            VStack(spacing: 12) {
                ForEach(WhisperModel.availableModels) { model in
                    onboardingModelRow(model)
                }
            }
            .frame(maxWidth: 380)

            Spacer()
        }
        .padding()
    }

    private func onboardingModelRow(_ model: WhisperModel) -> some View {
        let downloaded = modelManager.isModelDownloaded(model)
        let downloading = modelManager.isDownloading[model.id] ?? false
        let progress = modelManager.downloadProgress[model.id] ?? 0

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.headline)
                Text(model.fileSizeFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if downloading {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if downloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("Download") {
                    Task { try? await modelManager.downloadModel(model) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
    }
}
