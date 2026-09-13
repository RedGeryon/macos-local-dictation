import ApplicationServices
import Foundation
import OSLog

enum GlobalHotkeyEvent: Sendable {
    case pushToTalkBegan
    case pushToTalkEnded
    case toggleHandsFree
    case toggleConversation
    case readSelectedText
    case pauseOrResumeTextToSpeech
    case cancel
}

enum GlobalHotkeyRouting {
    static func shouldRouteEscape(dictationActive: Bool, textToSpeechActive: Bool, transientMessageVisible: Bool) -> Bool {
        dictationActive || textToSpeechActive || transientMessageVisible
    }
}

enum TextToSpeechSelectionCaptureGate {
    static func canBegin(canUseTextToSpeech: Bool, capturePending: Bool) -> Bool {
        canUseTextToSpeech && !capturePending
    }

    static func shouldConsumeReadShortcut(capturePending: Bool, matchesReadShortcut: Bool) -> Bool {
        capturePending && matchesReadShortcut
    }
}

enum TextToSpeechShortcutGate {
    static func readEnabled(settingsEnabled: Bool, canStart: Bool, isActive: Bool) -> Bool {
        settingsEnabled && canStart && !isActive
    }

    static func pauseEnabled(settingsEnabled: Bool, isSpeaking: Bool) -> Bool {
        settingsEnabled && isSpeaking
    }
}

@MainActor
final class GlobalHotkeyController {
    typealias Handler = @MainActor (GlobalHotkeyEvent) -> Void

    var onEvent: Handler?
    var bindings: ShortcutBindings = .standard
    /// While the Settings window records a new shortcut the tap must stay quiet so the
    /// old binding does not fire under the user's fingers.
    var isSuspended = false
    var isDictationActive = false
    var isDictationShortcutEnabled = false
    var isConversationShortcutEnabled = false
    var isLongDictationShortcutEnabled = false
    var isTextToSpeechReadShortcutEnabled = false
    var isTextToSpeechPauseShortcutEnabled = false
    var isTextToSpeechActive = false
    var isTextToSpeechSelectionCaptureActive = false
    var isTransientMessageVisible = false

    private let logger = Logger(subsystem: "org.localdictation.app", category: "GlobalHotkey")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var functionKeyDown = false
    private var functionKeyConsumed = false
    private var alternateShortcutDown = false
    private var conversationShortcutDown = false
    private var longDictationShortcutDown = false
    private var textToSpeechShortcutDown: Int64?

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
        logger.info("GLOBAL_HOTKEY tap_started")
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
        longDictationShortcutDown = false
        textToSpeechShortcutDown = nil
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

        guard !isSuspended else { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .keyDown, keyCode == 53, GlobalHotkeyRouting.shouldRouteEscape(
            dictationActive: isDictationActive,
            textToSpeechActive: isTextToSpeechActive || isTextToSpeechSelectionCaptureActive,
            transientMessageVisible: isTransientMessageVisible
        ) {
            onEvent?(.cancel)
            return true
        }

        if handleTextToSpeechShortcut(type: type, event: event, keyCode: keyCode, isRepeat: isRepeat) {
            return true
        }

        if handleConversationShortcut(type: type, event: event, keyCode: keyCode, isRepeat: isRepeat) {
            return true
        }

        if handleLongDictationShortcut(type: type, event: event, keyCode: keyCode, isRepeat: isRepeat) {
            return true
        }

        switch bindings.quickDictation {
        case .functionKey:
            return handleFunctionShortcut(type: type, event: event, keyCode: keyCode, isRepeat: isRepeat)
        case .keyboardShortcut(let shortcut):
            return handleAlternateShortcut(
                shortcut: shortcut,
                type: type,
                event: event,
                keyCode: keyCode,
                isRepeat: isRepeat
            )
        }
    }

    private func matchesRead(keyCode: Int64, flags: CGEventFlags) -> Bool {
        bindings.readSelectedText?.matches(keyCode: keyCode, flags: flags) ?? false
    }

    private func matchesPause(keyCode: Int64, flags: CGEventFlags) -> Bool {
        bindings.pauseOrResumeReadback?.matches(keyCode: keyCode, flags: flags) ?? false
    }

    private func handleTextToSpeechShortcut(
        type: CGEventType,
        event: CGEvent,
        keyCode: Int64,
        isRepeat: Bool
    ) -> Bool {
        if type == .keyUp, textToSpeechShortcutDown == keyCode {
            textToSpeechShortcutDown = nil
            return true
        }
        guard type == .keyDown else { return false }
        if textToSpeechShortcutDown == keyCode { return true }
        if TextToSpeechSelectionCaptureGate.shouldConsumeReadShortcut(
            capturePending: isTextToSpeechSelectionCaptureActive,
            matchesReadShortcut: matchesRead(keyCode: keyCode, flags: event.flags)
        ) {
            textToSpeechShortcutDown = keyCode
            logger.info("TTS_READ_SHORTCUT ignored capture_pending=true")
            return true
        }
        let matchesReadShortcut = matchesRead(keyCode: keyCode, flags: event.flags)
        if matchesReadShortcut, !isTextToSpeechReadShortcutEnabled {
            logger.info("TTS_READ_SHORTCUT ignored read_enabled=false")
            return false
        }
        if isTextToSpeechReadShortcutEnabled, matchesReadShortcut {
            textToSpeechShortcutDown = keyCode
            if !isRepeat {
                logger.info("TTS_READ_SHORTCUT matched")
                onEvent?(.readSelectedText)
            }
            return true
        }
        if isTextToSpeechPauseShortcutEnabled, isTextToSpeechActive,
           matchesPause(keyCode: keyCode, flags: event.flags) {
            textToSpeechShortcutDown = keyCode
            if !isRepeat { onEvent?(.pauseOrResumeTextToSpeech) }
            return true
        }
        return false
    }

    /// A press starts hands-free dictation; a second press inserts the result.
    private func handleLongDictationShortcut(
        type: CGEventType,
        event: CGEvent,
        keyCode: Int64,
        isRepeat: Bool
    ) -> Bool {
        guard let binding = bindings.toggleLongDictation else { return false }
        if type == .keyDown, binding.matches(keyCode: keyCode, flags: event.flags), isLongDictationShortcutEnabled {
            if !isRepeat, !longDictationShortcutDown {
                longDictationShortcutDown = true
                onEvent?(.toggleHandsFree)
            }
            return true
        }
        if type == .keyUp, keyCode == Int64(binding.keyCode), longDictationShortcutDown {
            longDictationShortcutDown = false
            return true
        }
        return false
    }

    private func handleConversationShortcut(
        type: CGEventType,
        event: CGEvent,
        keyCode: Int64,
        isRepeat: Bool
    ) -> Bool {
        guard let binding = bindings.toggleConversation else { return false }
        let matches = binding.matches(keyCode: keyCode, flags: event.flags)

        if type == .keyDown, matches, isConversationShortcutEnabled {
            if !isRepeat, !conversationShortcutDown {
                conversationShortcutDown = true
                onEvent?(.toggleConversation)
            }
            return true
        }
        if type == .keyUp, keyCode == Int64(binding.keyCode), conversationShortcutDown {
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
                guard isDictationShortcutEnabled else { return false }
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
        shortcut: KeyboardShortcut,
        type: CGEventType,
        event: CGEvent,
        keyCode: Int64,
        isRepeat: Bool
    ) -> Bool {
        guard keyCode == Int64(shortcut.keyCode) else { return false }
        guard isDictationShortcutEnabled || alternateShortcutDown else { return false }

        if type == .keyDown, shortcut.matches(keyCode: keyCode, flags: event.flags) {
            if !isRepeat, !alternateShortcutDown {
                alternateShortcutDown = true
                onEvent?(.pushToTalkBegan)
            }
            return true
        }
        // The key may be released after the modifiers, so the keyUp is matched on key alone.
        if type == .keyUp, alternateShortcutDown {
            alternateShortcutDown = false
            onEvent?(.pushToTalkEnded)
            return true
        }
        return false
    }
}
