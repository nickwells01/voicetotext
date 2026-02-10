import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var pipeline: TranscriptionPipeline
    @StateObject private var modelManager = ModelManager.shared
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            // Config at a glance
            configSection
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            // Last transcription
            if !appState.lastTranscription.isEmpty {
                lastTranscriptionSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Divider()
            }

            // Record button
            recordButton
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            // Footer
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text("VoiceToText")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch appState.recordingState {
        case .idle: return .green
        case .recording: return .red
        case .transcribing, .processing: return .orange
        case .error: return .red
        }
    }

    private var statusText: String {
        switch appState.recordingState {
        case .idle:
            return "Ready"
        case .recording:
            let mins = Int(appState.recordingDuration) / 60
            let secs = Int(appState.recordingDuration) % 60
            return String(format: "Recording %d:%02d", mins, secs)
        case .transcribing:
            return "Transcribing..."
        case .processing:
            return "Processing with AI..."
        case .error(let message):
            return message
        }
    }

    // MARK: - Config Section

    private var configSection: some View {
        VStack(spacing: 8) {
            configRow(label: "Model", value: currentModelName, icon: "cpu")
            configRow(label: "Activation", value: activationDescription, icon: "keyboard")
            configRow(label: "AI Cleanup", value: aiCleanupStatus, icon: "sparkles")
        }
    }

    private func configRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
        }
    }

    private var currentModelName: String {
        if let model = appState.selectedModel {
            let downloaded = modelManager.isModelDownloaded(model)
            if !downloaded {
                return "\(model.displayName) (not downloaded)"
            }
            let variant = appState.fastMode && modelManager.isFastModelDownloaded(model) ? "(Q5)" : "(Q8)"
            return "\(model.displayName) \(variant)"
        }
        return "None selected"
    }

    private var activationDescription: String {
        let mode = appState.currentActivationMode
        if appState.useFnDoubleTap {
            return "\(mode == .holdToTalk ? "Hold" : "Toggle") — Fn double-tap"
        }
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            return "\(mode == .holdToTalk ? "Hold" : "Toggle") — \(shortcut.description)"
        }
        return mode.displayName
    }

    private var aiCleanupStatus: String {
        let config = LLMConfig.load()
        if config.isEnabled && config.isValid {
            return "On (\(config.modelName))"
        } else if config.isEnabled {
            return "On (not configured)"
        }
        return "Off"
    }

    // MARK: - Last Transcription

    private var lastTranscriptionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last Transcription")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.lastTranscription, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Text(appState.lastTranscription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button {
            if appState.recordingState == .recording {
                pipeline.stopRecording()
            } else {
                pipeline.startRecording()
            }
        } label: {
            HStack {
                Spacer()
                Image(systemName: appState.recordingState == .recording ? "stop.fill" : "record.circle")
                Text(appState.recordingState == .recording ? "Stop Recording" : "Start Recording")
                    .fontWeight(.medium)
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(appState.recordingState == .recording ? .red : .accentColor)
        .disabled(appState.recordingState == .transcribing || appState.recordingState == .processing)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings...", systemImage: "gear")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}
