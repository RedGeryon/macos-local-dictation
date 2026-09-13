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

enum SelectedTextError: LocalizedError {
    case accessibilityPermissionRequired
    case noStandardSelection
    case secureField
    case emptySelection
    case captureInProgress

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required to read selected text. Allow this app in System Settings, then try again."
        case .noStandardSelection:
            return "This app does not expose its selected text to macOS. Use Read Clipboard instead."
        case .secureField:
            return "Text readback is disabled in password and secure text fields."
        case .emptySelection:
            return "Select text, then try Read Selected Text."
        case .captureInProgress:
            return "Text selection is already being checked."
        }
    }
}

enum SelectedTextClipboardRestorePolicy {
    static func shouldRestore(
        fallbackCopy: [(String, Data)],
        current: [(String, Data)],
        expectedChangeCount: Int,
        currentChangeCount: Int,
        targetUnchanged: Bool
    ) -> Bool {
        guard targetUnchanged, expectedChangeCount == currentChangeCount,
              fallbackCopy.count == current.count else { return false }
        return zip(fallbackCopy, current).allSatisfy { expected, observed in
            expected.0 == observed.0 && expected.1 == observed.1
        }
    }
}

struct SelectedTextPasteboardItemSnapshot {
    let values: [(NSPasteboard.PasteboardType, Data)]
}

enum SelectedTextPasteboardStorage {
    static func snapshot(_ pasteboard: NSPasteboard) -> [SelectedTextPasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            SelectedTextPasteboardItemSnapshot(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    static func signature(_ snapshots: [SelectedTextPasteboardItemSnapshot]) -> [(String, Data)] {
        snapshots.flatMap { snapshot in
            snapshot.values.map { ($0.0.rawValue, $0.1) }
        }.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1.lexicographicallyPrecedes(rhs.1) : lhs.0 < rhs.0
        }
    }

    static func restore(_ snapshots: [SelectedTextPasteboardItemSnapshot], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshots.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

enum SelectedTextCapturePolicy {
    static func requiresAccessibilityPermission(isTrusted: Bool) -> Bool {
        !isTrusted
    }

    static func isSecure(subrole: String?, roleDescription: String?) -> Bool {
        subrole == kAXSecureTextFieldSubrole as String
            || roleDescription?.localizedCaseInsensitiveContains("secure") == true
            || roleDescription?.localizedCaseInsensitiveContains("password") == true
    }

    static func supportsCopyFallback(role: String?) -> Bool {
        [kAXTextAreaRole as String, kAXTextFieldRole as String, "AXWebArea"].contains(role ?? "")
    }

    static func copiedText(_ value: String?, marker: String) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty && trimmed != marker ? trimmed : nil
    }
}

enum BrowserAccessibilityActivationPolicy {
    static let captureRetryMilliseconds = 750

    private static let supportedBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser"
    ]

    static func allows(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(supportedBundleIdentifiers.contains) ?? false
    }

    static func retryMilliseconds(for bundleIdentifier: String?) -> Int {
        allows(bundleIdentifier) ? captureRetryMilliseconds : 150
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
    private enum AXSelectionResult {
        case selected(String)
        case empty
        case unavailable
    }

    private struct SelectionCopyContext {
        let processIdentifier: pid_t
        let window: AXUIElement
        let focusedElement: AXUIElement?
    }

    private let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty"
    ]
    private let logger = Logger(subsystem: "org.localdictation.app", category: "Insertion")
    private var selectionCopyInProgress = false

    func captureTarget() -> InsertionTarget? {
        captureTargetOnce()
    }

    func selectedText(onWaitingForShortcutRelease: @escaping @MainActor () -> Void = {}) async throws -> String {
        guard !SelectedTextCapturePolicy.requiresAccessibilityPermission(isTrusted: AXIsProcessTrusted()) else {
            throw SelectedTextError.accessibilityPermissionRequired
        }
        guard !selectionCopyInProgress else { throw SelectedTextError.captureInProgress }
        selectionCopyInProgress = true
        defer { selectionCopyInProgress = false }

        guard let target = await captureTarget(retryingForMilliseconds: selectedTextCaptureRetryMilliseconds()) else {
            throw SelectedTextError.noStandardSelection
        }
        guard !target.isSecure else { throw SelectedTextError.secureField }
        guard let element = target.element else { throw SelectedTextError.noStandardSelection }

        var sawEmptySelection = false
        var copyFallbackCandidate: AXUIElement?
        for (index, candidate) in selectionCandidates(from: element).enumerated() {
            let candidateIsSecure = isSecure(element: candidate)
            if copyFallbackCandidate == nil,
               !candidateIsSecure,
               copyFallbackIsSupported(for: candidate) {
                copyFallbackCandidate = candidate
            }
            switch axSelection(in: candidate) {
            case .selected(let text):
                guard !candidateIsSecure else { throw SelectedTextError.secureField }
                return text
            case .empty:
                // Only the focused element is authoritative. Browser accessibility trees
                // commonly include unrelated, empty controls (including password controls).
                if index == 0 {
                    guard !candidateIsSecure else { throw SelectedTextError.secureField }
                    sawEmptySelection = true
                }
            case .unavailable: continue
            }
        }
        guard !sawEmptySelection else { throw SelectedTextError.emptySelection }
        guard copyFallbackCandidate != nil || hasBrowserAncestor(from: element),
              let context = selectionCopyContext(for: target) else {
            throw SelectedTextError.noStandardSelection
        }
        return try await selectedTextByCopying(
            target: target,
            context: context,
            onWaitingForShortcutRelease: onWaitingForShortcutRelease
        )
    }

    func clipboardText() throws -> String {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw SelectedTextError.emptySelection }
        return text
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

    private func selectedTextCaptureRetryMilliseconds() -> Int {
        BrowserAccessibilityActivationPolicy.retryMilliseconds(
            for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
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
        enableBrowserAccessibilityIfSupported(application, bundleIdentifier: frontmost.bundleIdentifier)
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
        let secure = SelectedTextCapturePolicy.isSecure(subrole: subrole, roleDescription: roleDescription)

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

    private func axSelection(in element: AXUIElement) -> AXSelectionResult {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let selected = value as? String {
            let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .selected(trimmed) }
            if let range = selectedRange(of: element), range.length == 0 { return .empty }
        }
        guard let range = selectedRange(of: element) else { return .unavailable }
        guard range.length > 0 else { return .empty }
        guard let selected = string(for: range, in: element) else { return .unavailable }
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .empty : .selected(trimmed)
    }

    private func selectionCandidates(from root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending = [root]
        while let element = pending.first, result.count < 24 {
            pending.removeFirst()
            result.append(element)
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { continue }
            pending.append(contentsOf: children.prefix(24 - result.count))
        }
        return result
    }

    private func isSecure(element: AXUIElement) -> Bool {
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute)
        return SelectedTextCapturePolicy.isSecure(subrole: subrole, roleDescription: roleDescription)
    }

    private func copyFallbackIsSupported(for element: AXUIElement) -> Bool {
        SelectedTextCapturePolicy.supportsCopyFallback(role: stringAttribute(element, kAXRoleAttribute))
    }

    private func hasBrowserAncestor(from element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<4 {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(value, to: AXUIElement.self)
            if copyFallbackIsSupported(for: current) { return true }
        }
        return false
    }

    private func selectionCopyContext(for target: InsertionTarget) -> SelectionCopyContext? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == target.processIdentifier,
              let window = focusedWindow(for: target.processIdentifier) else { return nil }
        let currentFocusedElement = focusedElement()
        if let targetElement = target.element {
            guard let currentFocusedElement, CFEqual(currentFocusedElement, targetElement) else { return nil }
        }
        return SelectionCopyContext(
            processIdentifier: target.processIdentifier,
            window: window,
            focusedElement: currentFocusedElement
        )
    }

    private func selectionTargetIsUnchanged(_ context: SelectionCopyContext) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == context.processIdentifier,
              let window = focusedWindow(for: context.processIdentifier) else { return false }
        if let expectedFocusedElement = context.focusedElement {
            guard let currentFocusedElement = focusedElement(),
                  CFEqual(currentFocusedElement, expectedFocusedElement) else { return false }
        }
        return CFEqual(window, context.window)
    }

    private func focusedWindow(for processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func enableBrowserAccessibilityIfSupported(_ application: AXUIElement, bundleIdentifier: String?) {
        guard BrowserAccessibilityActivationPolicy.allows(bundleIdentifier) else { return }
        // Chromium enables its basic accessibility tree after an app-role probe. This is
        // a normal read-only AX attribute, unlike unsupported browser-private setters.
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &role)
    }

    private func selectedTextByCopying(
        target: InsertionTarget,
        context: SelectionCopyContext,
        onWaitingForShortcutRelease: @escaping @MainActor () -> Void
    ) async throws -> String {
        onWaitingForShortcutRelease()
        try await waitForReadShortcutRelease()
        guard !Task.isCancelled, selectionTargetIsUnchanged(context) else {
            throw SelectedTextError.noStandardSelection
        }
        let pasteboard = NSPasteboard.general
        let original = snapshot(pasteboard)
        let marker = UUID().uuidString
        let markerType = NSPasteboard.PasteboardType("org.localdictation.selected-text-copy-marker")
        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount
        let markerItem = NSPasteboardItem()
        markerItem.setString(marker, forType: .string)
        markerItem.setString(marker, forType: markerType)
        guard pasteboard.writeObjects([markerItem]) else {
            if pasteboard.changeCount == clearedChangeCount { restore(original, to: pasteboard) }
            throw SelectedTextError.noStandardSelection
        }
        var expectedSignature = signature(snapshot(pasteboard))
        var expectedChangeCount = pasteboard.changeCount
        var awaitingOwnCopy = true
        defer {
            if SelectedTextClipboardRestorePolicy.shouldRestore(
                fallbackCopy: expectedSignature,
                current: signature(snapshot(pasteboard)),
                expectedChangeCount: expectedChangeCount,
                currentChangeCount: pasteboard.changeCount,
                targetUnchanged: awaitingOwnCopy || selectionTargetIsUnchanged(context)
            ) {
                restore(original, to: pasteboard)
            }
        }
        guard selectionTargetIsUnchanged(context), postCopyKey(to: target.processIdentifier) else {
            throw SelectedTextError.noStandardSelection
        }
        let copied = try await waitForCopyResult(
            from: pasteboard,
            markerChangeCount: expectedChangeCount,
            context: context
        )
        expectedChangeCount = copied.changeCount
        expectedSignature = signature(copied.items)
        awaitingOwnCopy = false
        guard selectionTargetIsUnchanged(context), pasteboard.changeCount == copied.changeCount else {
            throw SelectedTextError.noStandardSelection
        }
        guard let selected = SelectedTextCapturePolicy.copiedText(
            pasteboard.string(forType: .string),
            marker: marker
        ) else {
            throw SelectedTextError.emptySelection
        }
        return selected
    }

    private func waitForCopyResult(
        from pasteboard: NSPasteboard,
        markerChangeCount: Int,
        context: SelectionCopyContext
    ) async throws -> (items: [SelectedTextPasteboardItemSnapshot], changeCount: Int) {
        for _ in 0..<25 { // 500 ms lets browsers dispatch Cmd-C without leaving stale text behind.
            guard !Task.isCancelled else { throw CancellationError() }
            guard selectionTargetIsUnchanged(context) else { throw SelectedTextError.noStandardSelection }
            if pasteboard.changeCount != markerChangeCount {
                return (snapshot(pasteboard), pasteboard.changeCount)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SelectedTextError.emptySelection
    }

    private func waitForReadShortcutRelease() async throws {
        let readModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        while !Task.isCancelled {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(readModifiers).isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
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

    private func snapshot(_ pasteboard: NSPasteboard) -> [SelectedTextPasteboardItemSnapshot] {
        SelectedTextPasteboardStorage.snapshot(pasteboard)
    }

    private func signature(_ snapshots: [SelectedTextPasteboardItemSnapshot]) -> [(String, Data)] {
        SelectedTextPasteboardStorage.signature(snapshots)
    }

    private func restore(_ snapshots: [SelectedTextPasteboardItemSnapshot], to pasteboard: NSPasteboard) {
        SelectedTextPasteboardStorage.restore(snapshots, to: pasteboard)
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

    private func postCopyKey(to processIdentifier: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }
}
