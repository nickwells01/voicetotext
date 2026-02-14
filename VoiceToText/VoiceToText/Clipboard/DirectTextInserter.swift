import AppKit
import os

// MARK: - Direct Text Inserter

/// Inserts text directly into the focused text field via Accessibility API (AXUIElement).
/// Falls back to clipboard paste if the focused element is not a text field.
final class DirectTextInserter {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "DirectTextInserter")

    enum InsertResult {
        case inserted
        case notSupported(reason: String)
    }

    /// Check whether the focused UI element is an editable text field.
    func hasEditableTextField() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else { return false }

        let axElement = element as! AXUIElement

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, "AXComboBox", "AXSearchField"]
        guard textRoles.contains(where: { role.contains($0) }) else { return false }

        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable)
        return settableResult == .success && settable.boolValue
    }

    /// Attempt to insert text directly into the focused text field.
    func insert(text: String) -> InsertResult {
        guard AXIsProcessTrusted() else {
            return .notSupported(reason: "Accessibility not granted")
        }

        let systemWide = AXUIElementCreateSystemWide()

        // Get the focused UI element
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard focusResult == .success, let element = focusedElement else {
            return .notSupported(reason: "No focused element")
        }

        let axElement = element as! AXUIElement

        // Check if the element supports text value setting
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, "AXComboBox", "AXSearchField"]
        guard textRoles.contains(where: { role.contains($0) }) else {
            return .notSupported(reason: "Focused element is \(role), not a text field")
        }

        // Check if the element is editable
        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable)
        guard settableResult == .success, settable.boolValue else {
            return .notSupported(reason: "Text field is not editable")
        }

        // Get current value and selection to insert at cursor position
        var currentValueRef: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValueRef)
        var currentValue = currentValueRef as? String ?? ""

        // If the current value matches the placeholder, treat the field as empty
        var placeholderRef: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXPlaceholderValueAttribute as CFString, &placeholderRef)
        if let placeholder = placeholderRef as? String, currentValue == placeholder {
            currentValue = ""
        }

        var selectedRangeRef: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef)

        var newValue: String
        if let rangeValue = selectedRangeRef {
            // Insert at selection, replacing any selected text
            var cfRange = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) {
                let start = currentValue.index(currentValue.startIndex, offsetBy: min(cfRange.location, currentValue.count))
                let end = currentValue.index(start, offsetBy: min(cfRange.length, currentValue.count - cfRange.location))
                var mutableValue = currentValue
                mutableValue.replaceSubrange(start..<end, with: text)
                newValue = mutableValue
            } else {
                // Append to end
                newValue = currentValue + text
            }
        } else {
            // Append to end
            newValue = currentValue + text
        }

        // Set the new value
        let setResult = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newValue as CFTypeRef)

        if setResult == .success {
            logger.info("Direct text insertion succeeded (\(text.count) chars)")
            return .inserted
        } else {
            return .notSupported(reason: "AXUIElementSetAttributeValue failed: \(setResult.rawValue)")
        }
    }
}
