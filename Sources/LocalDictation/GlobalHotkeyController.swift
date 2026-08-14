import ApplicationServices
import Foundation

enum GlobalHotkeyEvent: Sendable {
    case pushToTalkBegan
    case pushToTalkEnded
    case toggleHandsFree
    case toggleConversation
    case cancel
}

enum GlobalShortcutMatcher {
    static func isConversationToggle(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == 8 else { return false } // C
        let required: CGEventFlags = [.maskControl, .maskAlternate]
        let disallowed: CGEventFlags = [.maskCommand, .maskShift]
        return flags.intersection(required) == required
            && flags.intersection(disallowed).isEmpty
    }
}

@MainActor
final class GlobalHotkeyController {
    typealias Handler = @MainActor (GlobalHotkeyEvent) -> Void

    var onEvent: Handler?
    var shortcut: DictationShortcut = .functionKey
    var isDictationActive = false
    var isConversationShortcutEnabled = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var functionKeyDown = false
    private var functionKeyConsumed = false
    private var alternateShortcutDown = false
    private var conversationShortcutDown = false

    var isRunning: Bool {
        guard let eventTap, CFMachPortIsValid(eventTap) else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func start() -> Bool {
        stop()
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: context
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTap = nil
        runLoopSource = nil
        functionKeyDown = false
        functionKeyConsumed = false
        alternateShortcutDown = false
        conversationShortcutDown = false
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<GlobalHotkeyController>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.handle(type: type, event: event)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .keyDown, keyCode == 53, isDictationActive {
            onEvent?(.cancel)
            return true
        }

        if handleConversationShortcut(type: type, event: event, keyCode: keyCode, isRepeat: isRepeat) {
            return true
        }

        switch shortcut {
        case .functionKey:
            return handleFunctionShortcut(type: type, event: event, keyCode: keyCode, isRepeat: isRepeat)
        case .controlOptionSpace:
            return handleAlternateShortcut(type: type, event: event, keyCode: keyCode, isRepeat: isRepeat)
        }
    }

    private func handleConversationShortcut(
        type: CGEventType,
        event: CGEvent,
        keyCode: Int64,
        isRepeat: Bool
    ) -> Bool {
        let matches = GlobalShortcutMatcher.isConversationToggle(
            keyCode: keyCode,
            flags: event.flags
        )

        if type == .keyDown, matches, isConversationShortcutEnabled {
            if !isRepeat, !conversationShortcutDown {
                conversationShortcutDown = true
                onEvent?(.toggleConversation)
            }
            return true
        }
        if type == .keyUp, keyCode == 8, conversationShortcutDown {
            conversationShortcutDown = false
            return true
        }
        return false
    }

    private func handleFunctionShortcut(
        type: CGEventType,
        event: CGEvent,
        keyCode: Int64,
        isRepeat: Bool
    ) -> Bool {
        if type == .flagsChanged {
            let isNowDown = event.flags.contains(.maskSecondaryFn)
            if isNowDown && !functionKeyDown {
                functionKeyDown = true
                functionKeyConsumed = false
                onEvent?(.pushToTalkBegan)
                return true
            } else if !isNowDown && functionKeyDown {
                functionKeyDown = false
                if !functionKeyConsumed { onEvent?(.pushToTalkEnded) }
                functionKeyConsumed = false
                return true
            }
            return false
        }

        if keyCode == 49, functionKeyDown {
            if type == .keyDown {
                if !isRepeat, !functionKeyConsumed {
                    functionKeyConsumed = true
                    onEvent?(.toggleHandsFree)
                }
                return true
            }
            if type == .keyUp, functionKeyConsumed { return true }
        }
        return false
    }

    private func handleAlternateShortcut(
        type: CGEventType,
        event: CGEvent,
        keyCode: Int64,
        isRepeat: Bool
    ) -> Bool {
        guard keyCode == 49 else { return false }
        let required: CGEventFlags = [.maskControl, .maskAlternate]
        let matches = event.flags.intersection(required) == required

        if type == .keyDown, matches {
            if !isRepeat, !alternateShortcutDown {
                alternateShortcutDown = true
                onEvent?(.pushToTalkBegan)
            }
            return true
        }
        if type == .keyUp, alternateShortcutDown {
            alternateShortcutDown = false
            onEvent?(.pushToTalkEnded)
            return true
        }
        return false
    }
}
