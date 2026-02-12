import SwiftUI
import KeyboardShortcuts

@main
struct VoiceToTextApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var pipeline = TranscriptionPipeline.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(pipeline)
        } label: {
            MenuBarIcon(state: appState.recordingState)
                .onAppear {
                    // First-time setup when menu bar icon appears
                    pipeline.setup()
                    if !appState.hasCompletedOnboarding {
                        openWindow(id: "onboarding")
                    }
                    #if DEBUG
                    if CommandLine.arguments.contains("--test-harness") {
                        Task {
                            // Wait for model to finish loading
                            print("[TestHarness] Waiting for model to load...")
                            while !pipeline.isModelReady {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                            }
                            print("[TestHarness] Model ready, launching harness")
                            await pipeline.runTestHarness()
                            print("[TestHarness] Harness complete, terminating")
                            NSApp.terminate(nil)
                        }
                    }
                    #endif
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(pipeline)
        }

        Window("Welcome to VoiceToText", id: "onboarding") {
            OnboardingView()
                .environmentObject(appState)
                .frame(width: 500, height: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

// MARK: - Menu Bar Icon

struct MenuBarIcon: View {
    let state: RecordingState

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "mic")
        case .recording:
            Image(systemName: "mic.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red)
        case .transcribing, .processing:
            Image(systemName: "waveform")
        case .error:
            Image(systemName: "mic.slash")
        }
    }
}
