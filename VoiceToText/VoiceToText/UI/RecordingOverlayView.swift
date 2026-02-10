import SwiftUI

struct RecordingOverlayView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var pipeline: TranscriptionPipeline

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 10) {
            statusIndicator
            statusLabel
            Spacer(minLength: 0)
            cancelButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 200, height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch appState.recordingState {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 12, height: 12)
                .scaleEffect(isPulsing ? 1.2 : 0.8)
                .opacity(isPulsing ? 1.0 : 0.6)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
                .onDisappear { isPulsing = false }
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
}
