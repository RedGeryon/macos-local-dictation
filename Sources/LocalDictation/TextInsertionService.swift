import AppKit
import ApplicationServices
import Foundation
import OSLog

enum TextInsertionError: LocalizedError {
    case noFocusedTextField
    case secureField
    case insertionFailed

    var errorDescription: String? {
        switch self {
        case .noFocusedTextField: return "Place the cursor in a text field and try again."
        case .secureField: return "Dictation is disabled in password and secure text fields."
        case .insertionFailed: return "The transcript could not be inserted into the focused app."
        }
    }
}

struct InsertionTarget {
    let element: AXUIElement?
    let processIdentifier: pid_t
    let applicationBundleIdentifier: String?
    let context: InsertionContext
    let isSecure: Bool
}

enum ApplicationPasteFallbackPolicy {
    // The Codex/ChatGPT composer accepts standard paste events but currently does not
    // publish AXFocusedUIElement. Keep this list deliberately narrow because an app-level
    // target cannot be inspected for secure/password-field metadata.
    private static let allowedBundleIdentifiers: Set<String> = [
        "com.openai.codex"
    ]

    static func allows(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return allowedBundleIdentifiers.contains(bundleIdentifier)
    }
}

@MainActor
final class TextInsertionService {
    private struct PasteboardItemSnapshot {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    private let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty"
    ]
    private let logger = Logger(subsystem: "org.localdictation.app", category: "Insertion")

    func captureTarget() -> InsertionTarget? {
        captureTargetOnce()
    }

    func captureTarget(retryingForMilliseconds milliseconds: Int) async -> InsertionTarget? {
        let attempts = max(1, milliseconds / 25)
        for attempt in 0...attempts {
            guard !Task.isCancelled else { return nil }
            if let target = captureTargetOnce() { return target }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        logger.error("TARGET_CAPTURE failed after \(milliseconds, privacy: .public)ms")
        return nil
    }

    private func captureTargetOnce() -> InsertionTarget? {
        if let element = focusedElement(), let target = makeTarget(from: element) {
            return target
        }
        return makeApplicationPasteFallbackTarget()
    }

    private func makeApplicationPasteFallbackTarget() -> InsertionTarget? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              ApplicationPasteFallbackPolicy.allows(frontmost.bundleIdentifier) else {
            return nil
        }
        logger.info(
            "TARGET_CAPTURE using application paste fallback for \(frontmost.bundleIdentifier ?? "unknown", privacy: .public)"
        )
        return InsertionTarget(
            element: nil,
            processIdentifier: frontmost.processIdentifier,
            applicationBundleIdentifier: frontmost.bundleIdentifier,
            context: InsertionContext(),
            isSecure: false
        )
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let systemResult = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        if systemResult == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
            if targetBelongsToAnotherProcess(element) { return element }
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        var applicationFocusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &applicationFocusedValue
        ) == .success,
        let applicationFocusedValue,
        CFGetTypeID(applicationFocusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(applicationFocusedValue, to: AXUIElement.self)
    }

    private func targetBelongsToAnotherProcess(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success
            && pid != ProcessInfo.processInfo.processIdentifier
    }

    private func makeTarget(from element: AXUIElement) -> InsertionTarget? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute)
        let secure = subrole == kAXSecureTextFieldSubrole as String
            || roleDescription?.localizedCaseInsensitiveContains("secure") == true
            || roleDescription?.localizedCaseInsensitiveContains("password") == true

        return InsertionTarget(
            element: Optional(element),
            processIdentifier: pid,
            applicationBundleIdentifier: bundleID,
            context: insertionContext(for: element),
            isSecure: secure
        )
    }

    func insert(_ text: String, into target: InsertionTarget, pressReturn: Bool) async throws {
        guard !target.isSecure else { throw TextInsertionError.secureField }
        guard !text.isEmpty else { return }

        var inserted = false
        if let element = target.element {
            var settable = DarwinBoolean(false)
            let canSetSelectedText = AXUIElementIsAttributeSettable(
                element,
                kAXSelectedTextAttribute as CFString,
                &settable
            ) == .success && settable.boolValue
            if canSetSelectedText {
                inserted = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    text as CFTypeRef
                ) == .success
            }
        }

        if !inserted {
            guard isCurrentlyFocused(target) else {
                throw TextInsertionError.insertionFailed
            }
            inserted = await pasteWithClipboardPreservation(text)
        }
        guard inserted else { throw TextInsertionError.insertionFailed }

        if pressReturn,
           !terminalBundleIdentifiers.contains(target.applicationBundleIdentifier ?? ""),
           isCurrentlyFocused(target) {
            try? await Task.sleep(for: .milliseconds(45))
            postKey(keyCode: 36, flags: [])
        }
    }

    private func isCurrentlyFocused(_ target: InsertionTarget) -> Bool {
        if target.element == nil {
            guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
            return frontmost.processIdentifier == target.processIdentifier
                && frontmost.bundleIdentifier == target.applicationBundleIdentifier
                && ApplicationPasteFallbackPolicy.allows(frontmost.bundleIdentifier)
        }

        guard let current = captureTarget() else { return false }
        guard !current.isSecure else { return false }
        if let currentElement = current.element,
           let targetElement = target.element,
           CFEqual(currentElement, targetElement) {
            return true
        }
        return current.processIdentifier == target.processIdentifier
    }

    private func insertionContext(for element: AXUIElement) -> InsertionContext {
        guard let selected = selectedRange(of: element) else { return InsertionContext() }
        let beforeLength = min(50, max(0, selected.location))
        let before = string(
            for: CFRange(location: selected.location - beforeLength, length: beforeLength),
            in: element
        ) ?? ""
        let after = string(
            for: CFRange(location: selected.location + selected.length, length: 20),
            in: element
        ) ?? ""
        return InsertionContext(textBeforeCursor: before, textAfterCursor: after)
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func string(for range: CFRange, in element: AXUIElement) -> String? {
        guard range.location >= 0,
              range.length >= 0,
              let parameter = AXValueCreate(.cfRange, [range]) else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func pasteWithClipboardPreservation(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let original = snapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        postKey(keyCode: 9, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(300))
        restore(original, to: pasteboard)
        return true
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private func restore(_ snapshots: [PasteboardItemSnapshot], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshots.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
