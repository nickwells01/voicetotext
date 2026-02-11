import SwiftUI

struct RecordingOverlayView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var pipeline: TranscriptionPipeline

    @State private var isPulsing = false
    @State private var cursorVisible = true

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if !appState.displayText.isEmpty || appState.recordingState == .transcribing {
                Divider().opacity(0.3)
                streamingTextArea
            }
            if let toast = appState.toastMessage {
                Divider().opacity(0.3)
                toastBar(toast)
            }
        }
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
        .onChange(of: appState.committedText) { _, _ in
            updateWindowHeight()
        }
        .onChange(of: appState.speculativeText) { _, _ in
            updateWindowHeight()
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            statusIndicator
            statusLabel
            Spacer(minLength: 0)

            // Show detected app context if available
            if let context = appState.detectedAppContext {
                Text(context)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            cancelButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 44)
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch appState.recordingState {
        case .recording:
            AudioWaveformView(levels: appState.audioLevels)
                .frame(width: 32, height: 16)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 12, height: 12)
        case .processing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 12, height: 12)
        default:
            EmptyView()
        }
    }

    // MARK: - Status Label

    private var statusLabel: some View {
        Text(labelText)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private var labelText: String {
        switch appState.recordingState {
        case .recording:
            let total = Int(appState.recordingDuration)
            let mins = total / 60
            let secs = total % 60
            return String(format: "%d:%02d Recording", mins, secs)
        case .transcribing:
            return "Transcribing..."
        case .processing:
            return "Cleaning up..."
        default:
            return ""
        }
    }

    // MARK: - Cancel Button

    private var cancelButton: some View {
        Button {
            pipeline.cancelRecording()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }

    // MARK: - Streaming Text Area

    private var streamingTextArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                streamingTextContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .id("streamingTextBottom")
            }
            .frame(maxHeight: 220)
            .onChange(of: appState.committedText) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("streamingTextBottom", anchor: .bottom)
                }
            }
            .onChange(of: appState.speculativeText) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("streamingTextBottom", anchor: .bottom)
                }
            }
        }
    }

    private var streamingTextContent: some View {
        let committed = appState.committedText
        let speculative = appState.speculativeText

        return (
            Text(committed)
                .foregroundColor(.primary) +
            Text(speculative.isEmpty ? "" : (committed.isEmpty ? "" : " ") + speculative)
                .foregroundColor(.primary.opacity(0.5)) +
            Text(cursorVisible ? " |" : "  ")
                .foregroundColor(.primary.opacity(0.4))
        )
        .font(.system(size: 13))
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startCursorBlink() }
    }

    // MARK: - Toast Bar

    private func toastBar(_ message: String) -> some View {
        HStack {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cursor Blink

    private func startCursorBlink() {
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            Task { @MainActor in
                cursorVisible.toggle()
            }
        }
    }

    // MARK: - Dynamic Window Sizing

    private func updateWindowHeight() {
        let text = appState.displayText
        guard !text.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: 13)
        let maxWidth: CGFloat = 340 - 28 // width minus horizontal padding
        let boundingRect = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )

        // Status bar (44) + divider (1) + text padding (16) + text height + toast if present
        var totalHeight = 44 + 1 + 16 + boundingRect.height + 8
        if appState.toastMessage != nil {
            totalHeight += 1 + 28 // divider + toast bar
        }
        RecordingOverlayWindow.shared.updateHeight(totalHeight)
    }
}

// MARK: - Audio Waveform View

struct AudioWaveformView: View {
    let levels: [Float]
    private let barCount = 12

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<barCount, id: \.self) { index in
                let level = barLevel(at: index)
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > 0.02 ? Color.red : Color.red.opacity(0.3))
                    .frame(width: 2, height: max(2, CGFloat(level) * 16))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }

    private func barLevel(at index: Int) -> Float {
        guard !levels.isEmpty else { return 0 }
        // Map bar index to the nearest sample in the levels array
        let ratio = Float(index) / Float(max(barCount - 1, 1))
        let sampleIndex = Int(ratio * Float(levels.count - 1))
        let clampedIndex = min(max(sampleIndex, 0), levels.count - 1)
        // Scale for visibility (RMS values are typically 0-0.1)
        return min(levels[clampedIndex] * 10, 1.0)
    }
}
