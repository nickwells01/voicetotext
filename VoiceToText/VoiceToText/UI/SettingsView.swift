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

            AdvancedTab()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 580)
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
                .onChange(of: appState.activationMode) { _ in
                    TranscriptionPipeline.shared.reloadHotKeys()
                }

                Picker("Trigger", selection: $appState.triggerMethod) {
                    ForEach(TriggerMethod.allCases) { method in
                        Text(method.displayName).tag(method.rawValue)
                    }
                }
                .onChange(of: appState.triggerMethod) { _ in
                    TranscriptionPipeline.shared.reloadHotKeys()
                }

                if appState.currentTriggerMethod == .fnHold || appState.currentTriggerMethod == .fnDoubleTap {
                    Text("Requires accessibility permission to detect the Fn key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appState.currentTriggerMethod == .fnDoubleTap {
                    HStack {
                        Text("Double-Tap Speed")
                        Slider(value: $appState.fnDoubleTapInterval, in: 0.2...0.8, step: 0.05) {
                            Text("Interval")
                        }
                        Text("\(Int(appState.fnDoubleTapInterval * 1000))ms")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                if appState.currentTriggerMethod == .keyboardShortcut {
                    HStack {
                        Text("Keyboard Shortcut")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleRecording)
                    }
                }
            }

            Section("Transcription") {
                Picker("Language", selection: $appState.selectedLanguage) {
                    Text("English").tag("en")
                    Text("Auto-Detect").tag("auto")
                    Divider()
                    ForEach(WhisperLanguage.allLanguages.filter({ $0 != .english && $0 != .auto }), id: \.rawValue) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .onChange(of: appState.selectedLanguage) { _ in
                    Task {
                        await TranscriptionPipeline.shared.loadSelectedModel()
                    }
                }

                if appState.selectedLanguage != "en" && appState.selectedLanguage != "auto",
                   let model = appState.selectedModel, model.fileName.contains(".en") {
                    Text("The selected model is English-only. Choose a multilingual model (XL Turbo, XXL) or switch language to English.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Remove Filler Words (um, uh, like...)", isOn: $appState.fillerWordRemoval)
                Toggle("Sound Feedback on Start/Stop", isOn: $appState.soundFeedback)
            }

            Section("Output") {
                Toggle("Direct Text Insertion (Accessibility API)", isOn: $appState.preferDirectInsertion)
                Text("Insert text directly into the focused field. Falls back to clipboard paste if unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Privacy Mode (All-Local Processing)", isOn: $appState.privacyMode)
                if appState.privacyMode {
                    Text("All transcription and AI processing stays on your Mac. No data is sent to external servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        VStack(spacing: 0) {
            Toggle("Fast Mode (Q5 — smaller & faster, slightly lower quality)", isOn: $appState.fastMode)
                .onChange(of: appState.fastMode) { _ in
                    Task {
                        await TranscriptionPipeline.shared.loadSelectedModel()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            List {
                ForEach(WhisperModel.availableModels) { model in
                    let coreMLKey = "\(model.id)-coreml"
                    let fastKey = "\(model.id)-fast"
                    ModelRow(
                        model: model,
                        isSelected: appState.selectedModelName == model.id,
                        isDownloaded: modelManager.isModelDownloaded(model),
                        isDownloading: modelManager.isDownloading[model.id] ?? false,
                        progress: modelManager.downloadProgress[model.id] ?? 0,
                        isFastDownloaded: modelManager.isFastModelDownloaded(model),
                        isFastDownloading: modelManager.isFastDownloading[fastKey] ?? false,
                        fastProgress: modelManager.fastDownloadProgress[fastKey] ?? 0,
                        isCoreMLDownloaded: modelManager.isCoreMLDownloaded(model),
                        isCoreMLDownloading: modelManager.isCoreMLDownloading[coreMLKey] ?? false,
                        coreMLProgress: modelManager.coreMLDownloadProgress[coreMLKey] ?? 0
                    ) {
                        appState.selectedModelName = model.id
                        Task {
                            await TranscriptionPipeline.shared.loadSelectedModel()
                        }
                    } onDownload: {
                        Task {
                            try? await modelManager.downloadModel(model)
                        }
                    } onDelete: {
                        try? modelManager.deleteModel(model)
                    } onFastDownload: {
                        Task {
                            try? await modelManager.downloadFastModel(model)
                        }
                    } onFastDelete: {
                        try? modelManager.deleteFastModel(model)
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
}

private struct ModelRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let progress: Double
    let isFastDownloaded: Bool
    let isFastDownloading: Bool
    let fastProgress: Double
    let isCoreMLDownloaded: Bool
    let isCoreMLDownloading: Bool
    let coreMLProgress: Double
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onFastDownload: () -> Void
    let onFastDelete: () -> Void
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
                    if isDownloaded {
                        badgeView(model.primaryQuantLabel, color: .green)
                    }
                    if isFastDownloaded && model.hasFastVariant {
                        badgeView("Q5", color: .orange)
                    }
                    if isCoreMLDownloaded {
                        badgeView("CoreML", color: .blue)
                    }
                }
                Text(model.hasFastVariant
                    ? "\(model.id) — \(model.primaryQuantLabel): \(model.fileSizeFormatted), Q5: \(model.q5FileSizeFormatted)"
                    : "\(model.id) — \(model.primaryQuantLabel): \(model.fileSizeFormatted)"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isDownloading {
                    downloadProgressRow(label: model.primaryQuantLabel, value: progress)
                }

                if isFastDownloading {
                    downloadProgressRow(label: "Q5", value: fastProgress)
                }

                if isCoreMLDownloading {
                    downloadProgressRow(label: "CoreML", value: coreMLProgress)
                }
            }

            Spacer()

            if isDownloading || isFastDownloading {
                EmptyView()
            } else if isDownloaded {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        if !isSelected {
                            Button("Use") { onSelect() }
                                .controlSize(.small)
                        }
                        Button("Delete \(model.primaryQuantLabel)", role: .destructive) { onDelete() }
                            .controlSize(.mini)
                    }
                    if model.hasFastVariant && !isFastDownloading {
                        if isFastDownloaded {
                            Button("Delete Q5", role: .destructive) { onFastDelete() }
                                .controlSize(.mini)
                        } else {
                            Button("Get Q5 (Fast)") { onFastDownload() }
                                .controlSize(.mini)
                        }
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

    private func badgeView(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func downloadProgressRow(label: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ProgressView(value: value)
                .progressViewStyle(.linear)
            Text("\(Int(value * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - AI Cleanup Tab

private struct AICleanupTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var config = LLMConfig.load()
    @State private var testResult: TestResult = .none
    @StateObject private var localLLM = LocalLLMManager.shared

    // AI Mode Presets
    @State private var selectedPresetId: UUID? = {
        guard let idString = UserDefaults.standard.string(forKey: StorageKey.activeAIModePresetId),
              let id = UUID(uuidString: idString) else { return nil }
        return id
    }()
    @State private var customPresets: [AIModePreset] = AIModePreset.loadCustomPresets()
    @State private var showingNewPreset = false
    @State private var newPresetName = ""

    // Custom Vocabulary
    @State private var vocabulary = CustomVocabulary.load()
    @State private var newWord = ""

    private enum TestResult {
        case none, testing, success, failure
    }

    private var allPresets: [AIModePreset] {
        AIModePreset.builtInPresets + customPresets
    }

    var body: some View {
        Form {
            Section("LLM Post-Processing") {
                Toggle("Enable AI Cleanup", isOn: $config.isEnabled)
                    .onChange(of: config.isEnabled) { _ in
                        config.save()
                        if config.isEnabled { loadLocalModelIfNeeded() }
                    }

                Picker("Provider", selection: $config.provider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: config.provider) { _ in
                    testResult = .none
                    config.save()
                    if config.isEnabled && config.provider == .local {
                        Task {
                            await localLLM.prepareModel(modelId: config.localModelId, systemPrompt: config.systemPrompt)
                        }
                    }
                }

                if config.isEnabled {
                    Toggle("Context-Aware Prompts", isOn: $appState.appContextEnabled)
                    Text("Adjusts AI prompts based on the active app (email, code editor, etc.)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if config.provider == .remote {
                remoteSection
            } else {
                localSection
            }

            if config.isEnabled {
                Section("AI Mode") {
                    HStack {
                        Picker("Preset", selection: $selectedPresetId) {
                            Text("Default").tag(nil as UUID?)
                            Divider()
                            ForEach(allPresets) { preset in
                                Text(preset.name).tag(preset.id as UUID?)
                            }
                        }
                        .onChange(of: selectedPresetId) { newId in
                            if let id = newId, let preset = allPresets.first(where: { $0.id == id }) {
                                config.systemPrompt = preset.systemPrompt
                                config.save()
                            }
                            AIModePreset.setActivePreset(allPresets.first { $0.id == newId })
                        }

                        Button(action: { showingNewPreset = true }) {
                            Image(systemName: "plus")
                        }
                        .help("Save current prompt as a new preset")

                        Button(action: deleteSelectedPreset) {
                            Image(systemName: "minus")
                        }
                        .disabled(selectedPresetId == nil || allPresets.first(where: { $0.id == selectedPresetId })?.isBuiltIn == true)
                        .help("Delete selected custom preset")
                    }

                    if showingNewPreset {
                        HStack {
                            TextField("Preset name", text: $newPresetName)
                                .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                saveNewPreset()
                            }
                            .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel") {
                                showingNewPreset = false
                                newPresetName = ""
                            }
                        }
                    }
                }
            }

            Section("System Prompt") {
                TextEditor(text: $config.systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .onChange(of: config.systemPrompt) { _ in config.save() }
            }

            if config.isEnabled {
                Section("Custom Vocabulary") {
                    Text("Words the AI should preserve exactly as spelled (product names, acronyms)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(vocabulary.words, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button(role: .destructive) {
                                vocabulary.words.removeAll { $0 == word }
                                vocabulary.save()
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField("Add word...", text: $newWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addVocabularyWord() }
                        Button("Add") {
                            addVocabularyWord()
                        }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Section {
                HStack {
                    Button(config.provider == .remote ? "Test Connection" : "Test Inference") {
                        runTest()
                    }
                    .disabled(!config.isValid || testResult == .testing || (config.provider == .local && !localLLM.state.isReady))

                    Spacer()

                    switch testResult {
                    case .none:
                        EmptyView()
                    case .testing:
                        ProgressView()
                            .controlSize(.small)
                    case .success:
                        Label(config.provider == .remote ? "Connected" : "Passed", systemImage: "checkmark.circle.fill")
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

    // MARK: - Remote Section

    private var remoteSection: some View {
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
    }

    // MARK: - Local Section

    private var localSection: some View {
        Section("Local Model (MLX)") {
            if !config.isCustomLocalModel {
                Picker("Model", selection: $config.localModelId) {
                    ForEach(LocalLLMModel.curatedModels) { model in
                        Text("\(model.displayName) (\(model.sizeLabel))").tag(model.id)
                    }
                }
                .onChange(of: config.localModelId) { _ in
                    config.save()
                    loadLocalModelIfNeeded()
                }
            }

            Toggle("Use custom HuggingFace model", isOn: $config.isCustomLocalModel)
                .onChange(of: config.isCustomLocalModel) { _ in config.save() }

            if config.isCustomLocalModel {
                TextField("HuggingFace Model ID", text: $config.localModelId)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { config.save(); loadLocalModelIfNeeded() }
                    .onChange(of: config.localModelId) { _ in config.save() }
                Text("e.g. mlx-community/Qwen2.5-3B-Instruct-4bit — press Return to load")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Model status and actions
            localModelStatusView
        }
    }

    @ViewBuilder
    private var localModelStatusView: some View {
        switch localLLM.state {
        case .unloaded:
            Button("Download & Load") {
                Task {
                    await localLLM.prepareModel(modelId: config.localModelId, systemPrompt: config.systemPrompt)
                }
            }
            .disabled(config.localModelId.isEmpty)

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .ready:
            HStack {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                if let modelId = localLLM.currentModelId {
                    Text(modelId.split(separator: "/").last.map(String.init) ?? modelId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Unload") {
                    Task { await localLLM.unloadModel() }
                }
                .controlSize(.small)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Error", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Retry") {
                    Task {
                        await localLLM.prepareModel(modelId: config.localModelId, systemPrompt: config.systemPrompt)
                    }
                }
                .controlSize(.small)
            }

        case .unloading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Unloading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Preset Management

    private func saveNewPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let preset = AIModePreset(name: name, systemPrompt: config.systemPrompt)
        customPresets.append(preset)
        AIModePreset.saveCustomPresets(customPresets)
        selectedPresetId = preset.id
        AIModePreset.setActivePreset(preset)
        showingNewPreset = false
        newPresetName = ""
    }

    private func deleteSelectedPreset() {
        guard let id = selectedPresetId,
              let index = customPresets.firstIndex(where: { $0.id == id }) else { return }
        customPresets.remove(at: index)
        AIModePreset.saveCustomPresets(customPresets)
        selectedPresetId = nil
        AIModePreset.setActivePreset(nil)
    }

    // MARK: - Vocabulary Management

    private func addVocabularyWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !vocabulary.words.contains(word) else { return }
        vocabulary.words.append(word)
        vocabulary.save()
        newWord = ""
    }

    // MARK: - Load Local Model

    private func loadLocalModelIfNeeded() {
        guard config.isEnabled, config.provider == .local, !config.localModelId.isEmpty else { return }
        if localLLM.currentModelId != config.localModelId || !localLLM.state.isReady {
            Task {
                await localLLM.prepareModel(modelId: config.localModelId, systemPrompt: config.systemPrompt)
            }
        }
    }

    // MARK: - Test

    private func runTest() {
        testResult = .testing
        let processor = LLMPostProcessor(config: config)
        Task {
            let success = await processor.testConnection()
            testResult = success ? .success : .failure
        }
    }
}

// MARK: - Advanced Tab

private struct AdvancedTab: View {
    @State private var pipelineConfig = PipelineConfig.load()

    var body: some View {
        Form {
            Section("Pipeline Tuning") {
                Text("These settings control the real-time transcription pipeline. Default values work well for most hardware.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Audio Window")
                    Slider(value: windowMsBinding, in: 4000...12000, step: 1000) {
                        Text("Window")
                    }
                    Text("\(pipelineConfig.windowMs / 1000)s")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }

                HStack {
                    Text("Commit Margin")
                    Slider(value: commitMarginBinding, in: 400...1200, step: 50) {
                        Text("Margin")
                    }
                    Text("\(pipelineConfig.commitMarginMs)ms")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                HStack {
                    Text("Tick Interval")
                    Slider(value: tickMsBinding, in: 150...500, step: 50) {
                        Text("Tick")
                    }
                    Text("\(pipelineConfig.tickMs)ms")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                HStack {
                    Text("Silence Timeout")
                    Slider(value: silenceMsBinding, in: 500...2000, step: 100) {
                        Text("Silence")
                    }
                    Text("\(pipelineConfig.silenceMs)ms")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            Section {
                Button("Reset to Defaults") {
                    pipelineConfig = PipelineConfig()
                    pipelineConfig.save()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // Bindings that save on change
    private var windowMsBinding: Binding<Double> {
        Binding(
            get: { Double(pipelineConfig.windowMs) },
            set: { pipelineConfig.windowMs = Int($0); pipelineConfig.save() }
        )
    }

    private var commitMarginBinding: Binding<Double> {
        Binding(
            get: { Double(pipelineConfig.commitMarginMs) },
            set: { pipelineConfig.commitMarginMs = Int($0); pipelineConfig.save() }
        )
    }

    private var tickMsBinding: Binding<Double> {
        Binding(
            get: { Double(pipelineConfig.tickMs) },
            set: { pipelineConfig.tickMs = Int($0); pipelineConfig.save() }
        )
    }

    private var silenceMsBinding: Binding<Double> {
        Binding(
            get: { Double(pipelineConfig.silenceMs) },
            set: { pipelineConfig.silenceMs = Int($0); pipelineConfig.save() }
        )
    }
}

// MARK: - About Tab

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "mic.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("VoiceToText")
                .font(.title)
                .fontWeight(.bold)

            Text("On-device speech-to-text for macOS")
                .font(.body)
                .foregroundStyle(.secondary)

            Text("Version 1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 6) {
                Label("Powered by whisper.cpp", systemImage: "waveform")
                Label("AI cleanup via MLX Swift", systemImage: "brain")
                Label("100% offline capable", systemImage: "lock.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
