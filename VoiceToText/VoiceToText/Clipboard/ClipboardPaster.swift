import AppKit
import Carbon.HIToolbox
import os

// MARK: - Clipboard Paster

@MainActor
final class ClipboardPaster {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "ClipboardPaster")

    // MARK: - Paste Text

    func paste(text: String) async {
        // Put text on clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Set transcribed text on pasteboard (\(text.count) chars)")

        // Small delay to ensure pasteboard update is visible to other apps
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Try to auto-paste via Cmd+V simulation
        if simulatePasteViaAppleScript() {
            logger.info("Auto-paste succeeded via AppleScript")
        } else if simulatePasteViaCGEvent() {
            logger.info("Auto-paste succeeded via CGEvent")
        } else {
            logger.warning("Auto-paste failed — text is on clipboard for manual Cmd+V")
        }
    }

    // MARK: - Paste via AppleScript (System Events)

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

    // MARK: - Paste via CGEvent (fallback)

    private func simulatePasteViaCGEvent() -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            logger.error("Failed to create CGEvents for paste")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgSessionEventTap)
        usleep(50_000) // 50ms
        keyUp.post(tap: .cgSessionEventTap)

        return true
    }
}
