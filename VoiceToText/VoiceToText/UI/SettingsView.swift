import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ModelTab()
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }

            AICleanupTab()
                .tabItem {
                    Label("AI Cleanup", systemImage: "sparkles")
                }
        }
        .frame(width: 480, height: 400)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Activation") {
                Picker("Activation Mode", selection: $appState.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Use Fn Double-Tap", isOn: $appState.useFnDoubleTap)

                Text("Requires accessibility permission to detect the Fn key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Keyboard Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleRecording)
                }
            }

            Section("Startup") {
                LaunchAtLogin.Toggle("Launch at Login")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Model Tab

private struct ModelTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var modelManager = ModelManager.shared

    var body: some View {
        List {
            ForEach(WhisperModel.availableModels) { model in
                let coreMLKey = "\(model.id)-coreml"
                ModelRow(
                    model: model,
                    isSelected: appState.selectedModelName == model.id,
                    isDownloaded: modelManager.isModelDownloaded(model),
                    isDownloading: modelManager.isDownloading[model.id] ?? false,
                    progress: modelManager.downloadProgress[model.id] ?? 0,
                    isCoreMLDownloaded: modelManager.isCoreMLDownloaded(model),
                    isCoreMLDownloading: modelManager.isCoreMLDownloading[coreMLKey] ?? false,
                    coreMLProgress: modelManager.coreMLDownloadProgress[coreMLKey] ?? 0
                ) {
                    appState.selectedModelName = model.id
                } onDownload: {
                    Task {
                        try? await modelManager.downloadModel(model)
                    }
                } onDelete: {
                    try? modelManager.deleteModel(model)
                } onCoreMLDownload: {
                    Task {
                        try? await modelManager.downloadCoreMLModel(for: model)
                    }
                } onCoreMLDelete: {
                    try? modelManager.deleteCoreMLModel(model)
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let progress: Double
    let isCoreMLDownloaded: Bool
    let isCoreMLDownloading: Bool
    let coreMLProgress: Double
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onCoreMLDownload: () -> Void
    let onCoreMLDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.headline)
                    if isSelected && isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    if isCoreMLDownloaded {
                        Text("CoreML")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text("\(model.id) - \(model.fileSizeFormatted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isDownloading {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }

                if isCoreMLDownloading {
                    HStack(spacing: 4) {
                        Text("CoreML:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ProgressView(value: coreMLProgress)
                            .progressViewStyle(.linear)
                        Text("\(Int(coreMLProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer()

            if isDownloading {
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if isDownloaded {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        if !isSelected {
                            Button("Use") { onSelect() }
                                .controlSize(.small)
                        }
                        Button("Delete", role: .destructive) { onDelete() }
                            .controlSize(.small)
                    }
                    if model.coreMLModelURL != nil && !isCoreMLDownloading {
                        if isCoreMLDownloaded {
                            Button("Remove CoreML", role: .destructive) { onCoreMLDelete() }
                                .controlSize(.mini)
                        } else {
                            Button("Get CoreML Accelerator") { onCoreMLDownload() }
                                .controlSize(.mini)
                        }
                    }
                }
            } else {
                Button("Download") { onDownload() }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - AI Cleanup Tab

private struct AICleanupTab: View {
    @State private var config = LLMConfig.load()
    @State private var testResult: TestResult = .none

    private enum TestResult {
        case none, testing, success, failure
    }

    var body: some View {
        Form {
            Section("LLM Post-Processing") {
                Toggle("Enable AI Cleanup", isOn: $config.isEnabled)
                    .onChange(of: config.isEnabled) { _ in config.save() }
            }

            Section("API Configuration") {
                TextField("API URL", text: $config.apiURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: config.apiURL) { _ in config.save() }

                SecureField("API Key", text: $config.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: config.apiKey) { _ in config.save() }

                TextField("Model Name", text: $config.modelName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: config.modelName) { _ in config.save() }
            }

            Section("System Prompt") {
                TextEditor(text: $config.systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .onChange(of: config.systemPrompt) { _ in config.save() }
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(!config.isValid || testResult == .testing)

                    Spacer()

                    switch testResult {
                    case .none:
                        EmptyView()
                    case .testing:
                        ProgressView()
                            .controlSize(.small)
                    case .success:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure:
                        Label("Failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func testConnection() {
        testResult = .testing
        let processor = LLMPostProcessor(config: config)
        Task {
            let success = await processor.testConnection()
            testResult = success ? .success : .failure
        }
    }
}
