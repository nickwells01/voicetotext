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

        // Save previous clipboard contents before overwriting
        let pasteboard = NSPasteboard.general
        let savedClipboard = saveClipboardContents(pasteboard)

        // Put text on clipboard
        let previousChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Verify clipboard was set
        guard pasteboard.changeCount != previousChangeCount else {
            logger.error("Failed to set pasteboard contents")
            restoreClipboardContents(savedClipboard, to: pasteboard)
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
                // Don't restore — user needs transcribed text on clipboard for manual paste
                return .copiedOnly(reason: "Could not restore focus to \(targetApp.localizedName ?? "target app")")
            }
        } else {
            // No target app — small delay for window server
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        // Primary: CGEvent posted to session event tap
        if simulatePasteViaCGEvent() {
            logger.info("Auto-paste succeeded via CGEvent")
            await restoreClipboardAfterPaste(savedClipboard, pasteboard: pasteboard)
            return .pasted
        }

        // Fallback: AppleScript via System Events
        if simulatePasteViaAppleScript() {
            logger.info("Auto-paste succeeded via AppleScript")
            await restoreClipboardAfterPaste(savedClipboard, pasteboard: pasteboard)
            return .pasted
        }

        logger.warning("Auto-paste failed — text is on clipboard for manual Cmd+V")
        // Don't restore — user needs transcribed text on clipboard for manual paste
        return .copiedOnly(reason: "Paste simulation failed")
    }

    // MARK: - Clipboard Save / Restore

    /// Snapshot of one pasteboard item: each type mapped to its raw data.
    private typealias SavedItem = [(NSPasteboard.PasteboardType, Data)]

    /// Save all items currently on the pasteboard so they can be restored later.
    private func saveClipboardContents(_ pasteboard: NSPasteboard) -> [SavedItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }

        var saved: [SavedItem] = []
        for item in items {
            var pairs: SavedItem = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    pairs.append((type, data))
                }
            }
            if !pairs.isEmpty {
                saved.append(pairs)
            }
        }
        if !saved.isEmpty {
            logger.info("Saved \(saved.count) clipboard item(s) for later restore")
        }
        return saved
    }

    /// Restore previously saved clipboard contents.
    private func restoreClipboardContents(_ saved: [SavedItem], to pasteboard: NSPasteboard) {
        guard !saved.isEmpty else { return }

        pasteboard.clearContents()
        for itemPairs in saved {
            let item = NSPasteboardItem()
            for (type, data) in itemPairs {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
        logger.info("Restored \(saved.count) clipboard item(s)")
    }

    /// Wait for the paste keystroke to be processed, then restore the clipboard.
    private func restoreClipboardAfterPaste(_ saved: [SavedItem], pasteboard: NSPasteboard) async {
        // Give the target app time to read the clipboard from the Cmd+V event
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        restoreClipboardContents(saved, to: pasteboard)
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
