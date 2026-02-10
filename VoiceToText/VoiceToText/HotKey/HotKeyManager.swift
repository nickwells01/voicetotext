import AppKit
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
    private var fnHoldActive: Bool = false
    private var fnPollTimer: Timer?

    // MARK: - Settings Accessors

    private var triggerMethod: TriggerMethod {
        let raw = UserDefaults.standard.string(forKey: StorageKey.triggerMethod) ?? TriggerMethod.fnHold.rawValue
        return TriggerMethod(rawValue: raw) ?? .fnHold
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

        switch triggerMethod {
        case .fnHold:
            setupFnHold()
        case .fnDoubleTap:
            setupFnDetector()
        case .keyboardShortcut:
            setupKeyboardShortcuts()
        }

        logger.info("HotKeyManager setup complete (trigger: \(self.triggerMethod.rawValue), mode: \(self.activationMode.rawValue))")
    }

    func teardown() {
        stopFnPolling()
        fnHoldActive = false
        fnDetector?.stop()
        fnDetector = nil
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {}
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {}
        isToggleActive = false
        logger.info("HotKeyManager torn down")
    }

    // MARK: - Fn Hold Path

    private func setupFnHold() {
        let detector = FnKeyDetector()
        let mode = activationMode

        switch mode {
        case .holdToTalk:
            detector.onFnDown = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard !self.fnHoldActive else { return }
                    self.fnHoldActive = true
                    self.logger.debug("Fn pressed - start recording (hold mode)")
                    self.onStartRecording?()
                    self.startFnPolling()
                }
            }
            // Event-tap based release (fires on some systems)
            detector.onFnUp = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.handleFnRelease(source: "event tap")
                }
            }

        case .toggle:
            detector.onFnDown = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.isToggleActive.toggle()
                    if self.isToggleActive {
                        self.logger.debug("Toggle ON via Fn press")
                        self.onStartRecording?()
                    } else {
                        self.logger.debug("Toggle OFF via Fn press")
                        self.onStopRecording?()
                    }
                }
            }
        }

        self.fnDetector = detector
        detector.start()
    }

    /// Called from either the event-tap onFnUp or the polling timer.
    /// The `fnHoldActive` flag ensures only the first caller triggers the stop.
    private func handleFnRelease(source: String) {
        guard fnHoldActive else { return }
        fnHoldActive = false
        stopFnPolling()
        logger.debug("Fn released (\(source)) - stop recording")
        onStopRecording?()
    }

    /// Poll NSEvent.modifierFlags to detect Fn release.
    /// macOS often consumes the Fn/Globe key release event before our CGEvent tap
    /// sees it, so the flagsChanged callback never fires. Polling catches the release.
    private func startFnPolling() {
        stopFnPolling()
        fnPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let fnHeld = NSEvent.modifierFlags.contains(.function)
                if !fnHeld {
                    self.handleFnRelease(source: "polling")
                }
            }
        }
    }

    private func stopFnPolling() {
        fnPollTimer?.invalidate()
        fnPollTimer = nil
    }

    // MARK: - Fn Double-Tap Path

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
