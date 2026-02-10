import Foundation
import KeyboardShortcuts
import os

// MARK: - HotKey Manager

/// Routes hotkey detection to either FnKeyDetector or KeyboardShortcuts based on user settings.
/// Supports both hold-to-talk and toggle activation modes.
@MainActor
final class HotKeyManager {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "HotKeyManager")

    // MARK: - Callbacks

    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?

    // MARK: - State

    private var fnDetector: FnKeyDetector?
    private var isToggleActive: Bool = false

    // MARK: - Settings Accessors

    private var useFnDoubleTap: Bool {
        UserDefaults.standard.bool(forKey: StorageKey.useFnDoubleTap)
    }

    private var activationMode: ActivationMode {
        let raw = UserDefaults.standard.string(forKey: StorageKey.activationMode) ?? ActivationMode.holdToTalk.rawValue
        return ActivationMode(rawValue: raw) ?? .holdToTalk
    }

    private var fnDoubleTapInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: StorageKey.fnDoubleTapInterval)
        return value > 0 ? value : 0.4
    }

    // MARK: - Setup / Teardown

    func setup() {
        teardown()

        if useFnDoubleTap {
            setupFnDetector()
        } else {
            setupKeyboardShortcuts()
        }

        logger.info("HotKeyManager setup complete (useFn: \(self.useFnDoubleTap), mode: \(self.activationMode.rawValue))")
    }

    func teardown() {
        fnDetector?.stop()
        fnDetector = nil
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {}
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {}
        isToggleActive = false
        logger.info("HotKeyManager torn down")
    }

    // MARK: - Fn Key Detector Path

    private func setupFnDetector() {
        let detector = FnKeyDetector()
        detector.doubleTapInterval = fnDoubleTapInterval

        let mode = activationMode

        switch mode {
        case .holdToTalk:
            // Double-tap Fn starts recording, releasing Fn stops recording
            detector.onDoubleTap = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.logger.debug("Double-tap Fn - start recording (hold mode)")
                    self.onStartRecording?()
                }
            }

            detector.onFnUp = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.logger.debug("Fn released - stop recording")
                    self.onStopRecording?()
                }
            }

        case .toggle:
            detector.onDoubleTap = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.isToggleActive.toggle()
                    if self.isToggleActive {
                        self.logger.debug("Toggle ON via double-tap")
                        self.onStartRecording?()
                    } else {
                        self.logger.debug("Toggle OFF via double-tap")
                        self.onStopRecording?()
                    }
                }
            }
        }

        self.fnDetector = detector
        detector.start()
    }

    // MARK: - KeyboardShortcuts Path

    private func setupKeyboardShortcuts() {
        let mode = activationMode

        switch mode {
        case .holdToTalk:
            KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.logger.debug("Shortcut key down - start recording")
                    self.onStartRecording?()
                }
            }
            KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.logger.debug("Shortcut key up - stop recording")
                    self.onStopRecording?()
                }
            }

        case .toggle:
            KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.isToggleActive.toggle()
                    if self.isToggleActive {
                        self.logger.debug("Toggle ON via shortcut")
                        self.onStartRecording?()
                    } else {
                        self.logger.debug("Toggle OFF via shortcut")
                        self.onStopRecording?()
                    }
                }
            }
        }
    }

    deinit {
        // Note: deinit cannot be @MainActor, so teardown should be called explicitly
    }
}
