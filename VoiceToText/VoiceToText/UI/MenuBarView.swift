import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var pipeline: TranscriptionPipeline
    @StateObject private var modelManager = ModelManager.shared
    @State private var showingHistory = false

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
                HStack(spacing: 4) {
                    Text("VoiceToText")
                        .font(.headline)
                    if appState.privacyMode {
                        Image(systemName: "lock.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
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

    @State private var llmConfig = LLMConfig.load()

    // MARK: - Config Section

    private var downloadedModels: [WhisperModel] {
        WhisperModel.availableModels.filter { modelManager.isModelDownloaded($0) }
    }

    private var configSection: some View {
        VStack(spacing: 8) {
            // Model picker
            configControl(icon: "cpu", label: "Model") {
                Picker("", selection: $appState.selectedModelName) {
                    ForEach(downloadedModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: appState.selectedModelName) { _ in
                    Task { await TranscriptionPipeline.shared.loadSelectedModel() }
                }
            }

            // Fast mode toggle (only when selected model has a downloaded fast variant)
            if let model = appState.selectedModel,
               model.hasFastVariant,
               modelManager.isFastModelDownloaded(model) {
                configControl(icon: "bolt", label: "Fast Mode") {
                    Toggle("", isOn: $appState.fastMode)
                        .labelsHidden()
                        .controlSize(.small)
                        .toggleStyle(.switch)
                        .onChange(of: appState.fastMode) { _ in
                            Task { await TranscriptionPipeline.shared.loadSelectedModel() }
                        }
                }
            }

            // Language picker
            configControl(icon: "globe", label: "Language") {
                Picker("", selection: $appState.selectedLanguage) {
                    Text("English").tag("en")
                    Text("Auto-Detect").tag("auto")
                    Divider()
                    ForEach(WhisperLanguage.allLanguages.filter { $0.code != "en" && $0.code != "auto" }, id: \.code) { lang in
                        Text(lang.displayName).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
            }

            // Activation mode picker
            configControl(icon: "keyboard", label: "Activation") {
                Picker("", selection: $appState.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
            }

            // AI Cleanup toggle
            configControl(icon: "sparkles", label: "AI Cleanup") {
                HStack(spacing: 4) {
                    if llmConfig.isEnabled && !llmConfig.isValid {
                        Text("(not configured)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if llmConfig.isEnabled {
                        Text(llmConfig.provider == .local ? "MLX" : "API")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: $llmConfig.isEnabled)
                        .labelsHidden()
                        .controlSize(.small)
                        .toggleStyle(.switch)
                        .onChange(of: llmConfig.isEnabled) { _ in
                            llmConfig.save()
                            if llmConfig.isEnabled && llmConfig.provider == .local {
                                Task {
                                    await LocalLLMManager.shared.prepareModel(
                                        modelId: llmConfig.localModelId,
                                        systemPrompt: llmConfig.systemPrompt
                                    )
                                }
                            }
                        }
                }
            }

            // AI Mode preset picker (when AI cleanup is enabled)
            if llmConfig.isEnabled {
                configControl(icon: "wand.and.stars", label: "AI Mode") {
                    Picker("", selection: Binding(
                        get: { AIModePreset.activePreset()?.id.uuidString ?? "none" },
                        set: { newValue in
                            if newValue == "none" {
                                AIModePreset.setActivePreset(nil)
                            } else if let preset = AIModePreset.allPresets().first(where: { $0.id.uuidString == newValue }) {
                                AIModePreset.setActivePreset(preset)
                            }
                        }
                    )) {
                        Text("Default").tag("none")
                        Divider()
                        ForEach(AIModePreset.allPresets()) { preset in
                            Text(preset.name).tag(preset.id.uuidString)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                }

                // LLM model picker
                if llmConfig.provider == .local {
                    configControl(icon: "brain", label: "LLM Model") {
                        Picker("", selection: $llmConfig.localModelId) {
                            ForEach(LocalLLMModel.curatedModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: llmConfig.localModelId) { _ in
                            llmConfig.save()
                            Task {
                                await LocalLLMManager.shared.prepareModel(
                                    modelId: llmConfig.localModelId,
                                    systemPrompt: llmConfig.systemPrompt
                                )
                            }
                        }
                    }
                } else {
                    configControl(icon: "brain", label: "LLM Model") {
                        Text(llmConfig.modelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func configControl<C: View>(icon: String, label: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Spacer()
            control()
        }
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

            Button {
                showingHistory = true
            } label: {
                Label("History", systemImage: "clock")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showingHistory) {
                HistoryView()
            }

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
