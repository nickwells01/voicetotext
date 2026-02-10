import AppKit
import Carbon.HIToolbox
import os

// MARK: - Clipboard Paster

@MainActor
final class ClipboardPaster {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "ClipboardPaster")

    // MARK: - Paste Text

    func paste(text: String) async {
        // Check accessibility first
        if !AXIsProcessTrusted() {
            logger.warning("Accessibility permission not granted — auto-paste will not work")
        }
        if !CGPreflightPostEventAccess() {
            logger.warning("CGPreflightPostEventAccess returned false — requesting access")
            CGRequestPostEventAccess()
        }

        // Put text on clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Set transcribed text on pasteboard (\(text.count) chars)")

        // Small delay to ensure pasteboard update is visible to other apps
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Primary: CGEvent posted to session event tap (proven approach from Maccy/Clipy)
        if simulatePasteViaCGEvent() {
            logger.info("Auto-paste succeeded via CGEvent")
            return
        }

        // Fallback: AppleScript via System Events
        if simulatePasteViaAppleScript() {
            logger.info("Auto-paste succeeded via AppleScript")
            return
        }

        logger.warning("Auto-paste failed — text is on clipboard for manual Cmd+V")
    }

    // MARK: - Paste via CGEvent (primary)

    private func simulatePasteViaCGEvent() -> Bool {
        guard AXIsProcessTrusted() else {
            logger.warning("CGEvent paste skipped: accessibility not granted")
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKeyCode = UInt16(kVK_ANSI_V)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            logger.error("Failed to create CGEvents for paste")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Post to session event tap — proven working approach used by Maccy, Clipy, Espanso.
        // postToPid is unreliable on modern macOS (silent failures).
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)

        logger.info("Posted paste events to cgSessionEventTap")
        return true
    }

    // MARK: - Paste via AppleScript (fallback)

    private func simulatePasteViaAppleScript() -> Bool {
        guard let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """) else {
            logger.error("Failed to create NSAppleScript")
            return false
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown"
            logger.warning("AppleScript paste failed: \(message)")
            return false
        }

        return true
    }
}
