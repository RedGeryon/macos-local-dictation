import AppKit
import CoreGraphics
import XCTest
@testable import LocalDictation

final class KeyboardShortcutTests: XCTestCase {
    private func makeDefaults(_ function: String = #function) -> UserDefaults {
        let suite = "org.localdictation.tests.shortcuts.\(function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - matches

    func testMatchesIgnoresCapsLockFunctionAndNumericPadFlags() {
        let shortcut = KeyboardShortcut(keyCode: 15, modifiers: [.control, .option])
        XCTAssertTrue(shortcut.matches(keyCode: 15, flags: [.maskControl, .maskAlternate]))
        XCTAssertTrue(shortcut.matches(
            keyCode: 15,
            flags: [.maskControl, .maskAlternate, .maskAlphaShift, .maskSecondaryFn, .maskNumericPad, .maskHelp, .maskNonCoalesced]
        ))
    }

    func testMatchesRejectsExtraOrMissingModifiersAndOtherKeys() {
        let shortcut = KeyboardShortcut(keyCode: 15, modifiers: [.control, .option])
        XCTAssertFalse(shortcut.matches(keyCode: 15, flags: [.maskControl, .maskAlternate, .maskCommand]))
        XCTAssertFalse(shortcut.matches(keyCode: 15, flags: [.maskControl, .maskAlternate, .maskShift]))
        XCTAssertFalse(shortcut.matches(keyCode: 15, flags: [.maskControl]))
        XCTAssertFalse(shortcut.matches(keyCode: 15, flags: []))
        XCTAssertFalse(shortcut.matches(keyCode: 8, flags: [.maskControl, .maskAlternate]))
    }

    func testMatchesAcceptsLeftAndRightModifierVariants() {
        let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option])
        // CGEventFlags carries the device-independent bit for either side of the keyboard.
        let leftSide = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | 0x0000_0001)
        let rightSide = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | 0x0000_2000)
        XCTAssertTrue(shortcut.matches(keyCode: 8, flags: leftSide))
        XCTAssertTrue(shortcut.matches(keyCode: 8, flags: rightSide))
    }

    func testMatchesShortcutWithNoModifiers() {
        let shortcut = KeyboardShortcut(keyCode: 53)
        XCTAssertTrue(shortcut.matches(keyCode: 53, flags: []))
        XCTAssertTrue(shortcut.matches(keyCode: 53, flags: [.maskAlphaShift]))
        XCTAssertFalse(shortcut.matches(keyCode: 53, flags: [.maskShift]))
    }

    // MARK: - display

    func testDisplayStringUsesMacOSSymbolOrder() {
        let all = KeyboardShortcut(keyCode: 15, modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘R")
        XCTAssertEqual(KeyboardShortcut(keyCode: 15, modifiers: [.control, .option]).displayString, "⌃⌥R")
        XCTAssertEqual(KeyboardShortcut(keyCode: 8, modifiers: [.control, .option]).displayString, "⌃⌥C")
        XCTAssertEqual(KeyboardShortcut(keyCode: 35, modifiers: [.control, .option]).displayString, "⌃⌥P")
    }

    func testDisplayStringNamesNonPrintingKeys() {
        XCTAssertEqual(KeyboardShortcut(keyCode: 49, modifiers: [.control, .option]).displayString, "⌃⌥Space")
        XCTAssertEqual(KeyboardShortcut(keyCode: 96, modifiers: [.command]).displayString, "⌘F5")
        XCTAssertEqual(KeyboardShortcut(keyCode: 122).displayString, "F1")
        XCTAssertEqual(KeyboardShortcut(keyCode: 90).displayString, "F20")
        XCTAssertEqual(KeyboardShortcut(keyCode: 36).displayString, "Return")
        XCTAssertEqual(KeyboardShortcut(keyCode: 48).displayString, "Tab")
        XCTAssertEqual(KeyboardShortcut(keyCode: 51).displayString, "Delete")
        XCTAssertEqual(KeyboardShortcut(keyCode: 53).displayString, "Escape")
        XCTAssertEqual(KeyboardShortcut(keyCode: 123).displayString, "←")
        XCTAssertEqual(KeyboardShortcut(keyCode: 126).displayString, "↑")
        XCTAssertEqual(KeyboardShortcut(keyCode: 124).displayString, "→")
        XCTAssertEqual(KeyboardShortcut(keyCode: 125).displayString, "↓")
        XCTAssertEqual(KeyboardShortcut(keyCode: 115).displayString, "Home")
        XCTAssertEqual(KeyboardShortcut(keyCode: 119).displayString, "End")
        XCTAssertEqual(KeyboardShortcut(keyCode: 116).displayString, "Page Up")
        XCTAssertEqual(KeyboardShortcut(keyCode: 121).displayString, "Page Down")
        XCTAssertEqual(KeyboardShortcut(keyCode: 82).displayString, "Keypad 0")
    }

    func testDisplayStringFallsBackForUnknownKeyCodes() {
        XCTAssertEqual(KeyboardShortcut(keyCode: 250).displayString, "Key 250")
    }

    // MARK: - menu equivalents

    func testMenuKeyEquivalents() {
        XCTAssertEqual(KeyboardShortcut(keyCode: 15, modifiers: [.control, .option]).menuKeyEquivalent, "r")
        XCTAssertEqual(KeyboardShortcut(keyCode: 8, modifiers: [.control, .option]).menuKeyEquivalent, "c")
        XCTAssertEqual(KeyboardShortcut(keyCode: 49).menuKeyEquivalent, " ")
        XCTAssertEqual(KeyboardShortcut(keyCode: 36).menuKeyEquivalent, "\r")
        XCTAssertEqual(KeyboardShortcut(keyCode: 53).menuKeyEquivalent, "\u{1b}")
        XCTAssertEqual(KeyboardShortcut(keyCode: 51).menuKeyEquivalent, "\u{8}")
        XCTAssertEqual(
            KeyboardShortcut(keyCode: 122).menuKeyEquivalent,
            String(UnicodeScalar(UInt32(NSF1FunctionKey))!)
        )
        XCTAssertEqual(
            KeyboardShortcut(keyCode: 126).menuKeyEquivalent,
            String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
        )
        XCTAssertEqual(KeyboardShortcut(keyCode: 250).menuKeyEquivalent, "")
    }

    func testMenuKeyEquivalentModifierMask() {
        let shortcut = KeyboardShortcut(keyCode: 15, modifiers: [.control, .option, .shift, .command])
        XCTAssertEqual(shortcut.menuKeyEquivalentModifierMask, [.control, .option, .shift, .command])
        XCTAssertEqual(KeyboardShortcut(keyCode: 15).menuKeyEquivalentModifierMask, [])
    }

    // MARK: - usability

    func testIsUsableAsGlobalShortcut() {
        XCTAssertTrue(KeyboardShortcut(keyCode: 15, modifiers: [.control]).isUsableAsGlobalShortcut)
        XCTAssertTrue(KeyboardShortcut(keyCode: 15, modifiers: [.option]).isUsableAsGlobalShortcut)
        XCTAssertTrue(KeyboardShortcut(keyCode: 15, modifiers: [.command]).isUsableAsGlobalShortcut)
        XCTAssertTrue(KeyboardShortcut(keyCode: 15, modifiers: [.control, .option]).isUsableAsGlobalShortcut)
        // Function keys stand alone.
        XCTAssertTrue(KeyboardShortcut(keyCode: 122).isUsableAsGlobalShortcut)
        XCTAssertTrue(KeyboardShortcut(keyCode: 90, modifiers: [.shift]).isUsableAsGlobalShortcut)
        // Plain keys and shift-only combinations are not.
        XCTAssertFalse(KeyboardShortcut(keyCode: 15).isUsableAsGlobalShortcut)
        XCTAssertFalse(KeyboardShortcut(keyCode: 15, modifiers: [.shift]).isUsableAsGlobalShortcut)
        XCTAssertFalse(KeyboardShortcut(keyCode: 49, modifiers: [.shift]).isUsableAsGlobalShortcut)
    }

    // MARK: - DictationTrigger

    func testDictationTriggerTitles() {
        XCTAssertEqual(DictationTrigger.functionKey.title, "Hold Fn")
        XCTAssertTrue(DictationTrigger.functionKey.isFunctionKey)
        XCTAssertNil(DictationTrigger.functionKey.shortcut)

        let space = KeyboardShortcut(keyCode: 49, modifiers: [.control, .option])
        let trigger = DictationTrigger.keyboardShortcut(space)
        XCTAssertEqual(trigger.title, "Hold ⌃⌥Space")
        XCTAssertFalse(trigger.isFunctionKey)
        XCTAssertEqual(trigger.shortcut, space)
    }

    func testShortcutActionCopyIsPresent() {
        for action in ShortcutAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.detail.isEmpty)
        }
        XCTAssertEqual(ShortcutAction.quickDictation.title, "Quick Dictation")
        XCTAssertEqual(ShortcutAction.toggleConversation.title, "Conversation Transcript")
        XCTAssertEqual(ShortcutAction.readSelectedText.title, "Read Selected Text")
        XCTAssertEqual(ShortcutAction.pauseOrResumeReadback.title, "Pause or Resume Readback")
    }

    // MARK: - ShortcutBindings

    func testStandardBindingsMatchShippedDefaults() {
        let standard = ShortcutBindings.standard
        XCTAssertEqual(standard.quickDictation, .functionKey)
        XCTAssertEqual(standard.toggleConversation, KeyboardShortcut(keyCode: 8, modifiers: [.control, .option]))
        XCTAssertEqual(standard.readSelectedText, KeyboardShortcut(keyCode: 15, modifiers: [.control, .option]))
        XCTAssertEqual(standard.pauseOrResumeReadback, KeyboardShortcut(keyCode: 35, modifiers: [.control, .option]))
    }

    func testSubscriptGetAndSet() {
        var bindings = ShortcutBindings.standard
        XCTAssertNil(bindings[.quickDictation])
        XCTAssertEqual(bindings[.readSelectedText], KeyboardShortcut(keyCode: 15, modifiers: [.control, .option]))

        let newRead = KeyboardShortcut(keyCode: 17, modifiers: [.command, .shift])
        bindings[.readSelectedText] = newRead
        XCTAssertEqual(bindings.readSelectedText, newRead)

        bindings[.pauseOrResumeReadback] = nil
        XCTAssertNil(bindings.pauseOrResumeReadback)

        let space = KeyboardShortcut(keyCode: 49, modifiers: [.control, .option])
        bindings[.quickDictation] = space
        XCTAssertEqual(bindings.quickDictation, .keyboardShortcut(space))
        XCTAssertEqual(bindings[.quickDictation], space)

        // Quick Dictation always keeps a trigger.
        bindings[.quickDictation] = nil
        XCTAssertEqual(bindings.quickDictation, .keyboardShortcut(space))
    }

    func testConflictsFindsDuplicateBindings() {
        XCTAssertTrue(ShortcutBindings.standard.conflicts().isEmpty)

        var bindings = ShortcutBindings.standard
        bindings.pauseOrResumeReadback = bindings.readSelectedText
        let conflicts = bindings.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.0, .readSelectedText)
        XCTAssertEqual(conflicts.first?.1, .pauseOrResumeReadback)
    }

    func testConflictsIncludesQuickDictationWhenItUsesAKeyboardShortcut() {
        var bindings = ShortcutBindings.standard
        let shared = KeyboardShortcut(keyCode: 8, modifiers: [.control, .option])
        bindings.quickDictation = .keyboardShortcut(shared)
        let conflicts = bindings.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.0, .quickDictation)
        XCTAssertEqual(conflicts.first?.1, .toggleConversation)

        // The Fn trigger can never collide with a key combination.
        bindings.quickDictation = .functionKey
        XCTAssertTrue(bindings.conflicts().isEmpty)
    }

    func testPersistAndLoadRoundTripsThroughJSON() {
        let defaults = makeDefaults()
        var bindings = ShortcutBindings.standard
        bindings.quickDictation = .keyboardShortcut(KeyboardShortcut(keyCode: 49, modifiers: [.control, .option]))
        bindings.toggleConversation = KeyboardShortcut(keyCode: 11, modifiers: [.command, .shift])
        bindings.pauseOrResumeReadback = nil
        bindings.persist(to: defaults)

        XCTAssertNotNil(defaults.data(forKey: ShortcutBindings.bindingsKey))
        XCTAssertEqual(ShortcutBindings.load(defaults: defaults), bindings)
    }

    func testLoadMigratesLegacyControlOptionSpace() {
        let defaults = makeDefaults()
        defaults.set("controlOptionSpace", forKey: ShortcutBindings.legacyDictationShortcutKey)
        let loaded = ShortcutBindings.load(defaults: defaults)
        XCTAssertEqual(
            loaded.quickDictation,
            .keyboardShortcut(KeyboardShortcut(keyCode: 49, modifiers: [.control, .option]))
        )
        XCTAssertEqual(loaded.toggleConversation, ShortcutBindings.standard.toggleConversation)
        XCTAssertEqual(loaded.readSelectedText, ShortcutBindings.standard.readSelectedText)
        XCTAssertEqual(loaded.pauseOrResumeReadback, ShortcutBindings.standard.pauseOrResumeReadback)
    }

    func testLoadFallsBackToFunctionKeyWithoutStoredValues() {
        XCTAssertEqual(ShortcutBindings.load(defaults: makeDefaults()), .standard)

        let legacyFunctionKey = makeDefaults()
        legacyFunctionKey.set("functionKey", forKey: ShortcutBindings.legacyDictationShortcutKey)
        XCTAssertEqual(ShortcutBindings.load(defaults: legacyFunctionKey), .standard)
    }

    func testStoredBindingsWinOverLegacyKey() {
        let defaults = makeDefaults()
        defaults.set("controlOptionSpace", forKey: ShortcutBindings.legacyDictationShortcutKey)
        ShortcutBindings.standard.persist(to: defaults)
        XCTAssertEqual(ShortcutBindings.load(defaults: defaults), .standard)
    }

    func testDictationSettingsStopWritingTheLegacyKey() {
        let defaults = makeDefaults()
        defaults.set("controlOptionSpace", forKey: ShortcutBindings.legacyDictationShortcutKey)
        var settings = DictationSettings(defaults: defaults)
        XCTAssertEqual(
            settings.quickDictationTrigger,
            .keyboardShortcut(KeyboardShortcut(keyCode: 49, modifiers: [.control, .option]))
        )
        settings.bindings = .standard
        settings.persist(to: defaults)

        // The legacy value is left untouched but is no longer written or read back.
        XCTAssertEqual(ShortcutBindings.load(defaults: defaults), .standard)
        XCTAssertEqual(DictationSettings(defaults: defaults).bindings, .standard)
    }
}
