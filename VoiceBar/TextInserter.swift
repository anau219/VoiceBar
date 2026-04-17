import AppKit
import Foundation

enum TextInserter {
    // CGEvent unicode injection caps at 200 UTF-16 code units
    private static let unicodeLimit = 200

    /// Insert text at cursor:
    /// 1. AX API with verification — no clipboard touch, works in native text fields
    /// 2. Cmd+V — universal fallback, text is already on clipboard from AppState
    /// CGEvent unicode was removed: postToPid silently "succeeds" even when the target
    /// app ignores the event, so it blocked Cmd+V from ever running.
    static func insertText(_ text: String) {
        let trusted = AXIsProcessTrusted()
        let targetApp = NSWorkspace.shared.frontmostApplication
        let targetPID = targetApp?.processIdentifier ?? 0
        AppState.log("insertText: length=\(text.count), AXTrusted=\(trusted), target=\(targetApp?.localizedName ?? "?") PID=\(targetPID)")

        // AX only if trusted — silently fails without permission
        if trusted, let element = focusedTextElement(), insertViaAX(text, into: element) {
            AppState.log("insertText: AX success")
            return
        }

        // Cmd+V — works even without AX trust via session broadcast
        simulatePaste(targetPID: trusted ? targetPID : 0)
        AppState.log("insertText: Cmd+V (trusted=\(trusted))")
    }

    // MARK: - Method 1: Accessibility API with verification

    private static func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success else { return nil }

        let element = focusedElement as! AXUIElement

        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return nil }

        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        guard textRoles.contains(role) else {
            AppState.log("insertText: AX role '\(role)' not a text field, skipping AX")
            return nil
        }

        return element
    }

    private static func insertViaAX(_ text: String, into element: AXUIElement) -> Bool {
        // Capture state before
        var valueBefore: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueBefore)
        let textBefore = valueBefore as? String

        // Attempt insertion at cursor (replaces selected text if any)
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        guard result == .success else {
            AppState.log("insertText: AX set returned \(result.rawValue)")
            return false
        }

        // Verify text actually changed — AX often lies about success
        var valueAfter: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueAfter)
        let textAfter = valueAfter as? String

        let changed = textAfter != textBefore
        AppState.log("insertText: AX verification — changed=\(changed)")
        return changed
    }

    // MARK: - Method 2: CGEvent unicode → target PID

    private static func insertViaCGEventUnicode(_ text: String, pid: pid_t) -> Bool {
        let utf16 = Array(text.utf16)

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            AppState.log("insertText: CGEvent creation failed")
            return false
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        keyDown.postToPid(pid)
        usleep(2000) // 2ms between down and up
        keyUp.postToPid(pid)

        AppState.log("insertText: CGEvent unicode posted \(utf16.count) chars to PID \(pid)")
        return true
    }

    // MARK: - Method 3: Simulate Cmd+V

    static func simulatePaste(targetPID: pid_t = 0) {
        // Use V key — keyboard-layout-safe since Cmd+V is always Cmd+V
        let vKeyCode: CGKeyCode = 0x09

        if targetPID > 0 {
            // Target specific app for reliability
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.postToPid(targetPID)

            usleep(10_000) // 10ms

            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.postToPid(targetPID)
        } else {
            // Broadcast to session
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cgSessionEventTap)

            usleep(10_000)

            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cgSessionEventTap)
        }

        AppState.log("insertText: Cmd+V posted to PID=\(targetPID)")
    }
}
