import AppKit
import Carbon.HIToolbox
import os

// MARK: - Paste Result

enum PasteResult {
    case pasted
    case copiedOnly(reason: String)
}

// MARK: - Clipboard Paster

@MainActor
final class ClipboardPaster {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "ClipboardPaster")

    // MARK: - Focus Tracking

    /// Record the current frontmost application for later focus restoration.
    func recordFrontmostApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    // MARK: - Paste Text

    func paste(text: String, targetApp: NSRunningApplication? = nil) async -> PasteResult {
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
        let previousChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Verify clipboard was set
        guard pasteboard.changeCount != previousChangeCount else {
            logger.error("Failed to set pasteboard contents")
            return .copiedOnly(reason: "Clipboard write failed")
        }
        logger.info("Set transcribed text on pasteboard (\(text.count) chars)")

        // Attempt to activate target app
        if let targetApp {
            targetApp.activate()

            // Brief delay for app activation
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

            // Verify focus was restored
            let currentFrontmost = NSWorkspace.shared.frontmostApplication
            if currentFrontmost?.processIdentifier != targetApp.processIdentifier {
                logger.warning("Failed to restore focus to \(targetApp.localizedName ?? "unknown"). Text is on clipboard.")
                return .copiedOnly(reason: "Could not restore focus to \(targetApp.localizedName ?? "target app")")
            }
        } else {
            // No target app — small delay for window server
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        // Primary: CGEvent posted to session event tap
        if simulatePasteViaCGEvent() {
            logger.info("Auto-paste succeeded via CGEvent")
            return .pasted
        }

        // Fallback: AppleScript via System Events
        if simulatePasteViaAppleScript() {
            logger.info("Auto-paste succeeded via AppleScript")
            return .pasted
        }

        logger.warning("Auto-paste failed — text is on clipboard for manual Cmd+V")
        return .copiedOnly(reason: "Paste simulation failed")
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
