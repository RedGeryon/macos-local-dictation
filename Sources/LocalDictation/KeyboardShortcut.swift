import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A single recordable keyboard shortcut: one key plus the ⌃⌥⇧⌘ modifiers held with it.
struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int

        init(rawValue: Int) { self.rawValue = rawValue }

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        init(eventFlags: CGEventFlags) {
            var result: Modifiers = []
            if eventFlags.contains(.maskControl) { result.insert(.control) }
            if eventFlags.contains(.maskAlternate) { result.insert(.option) }
            if eventFlags.contains(.maskShift) { result.insert(.shift) }
            if eventFlags.contains(.maskCommand) { result.insert(.command) }
            self = result
        }

        init(modifierFlags: NSEvent.ModifierFlags) {
            var result: Modifiers = []
            if modifierFlags.contains(.control) { result.insert(.control) }
            if modifierFlags.contains(.option) { result.insert(.option) }
            if modifierFlags.contains(.shift) { result.insert(.shift) }
            if modifierFlags.contains(.command) { result.insert(.command) }
            self = result
        }

        var modifierFlags: NSEvent.ModifierFlags {
            var result: NSEvent.ModifierFlags = []
            if contains(.control) { result.insert(.control) }
            if contains(.option) { result.insert(.option) }
            if contains(.shift) { result.insert(.shift) }
            if contains(.command) { result.insert(.command) }
            return result
        }

        /// ⌃⌥⇧⌘, in the order macOS prints them.
        var displayString: String {
            var result = ""
            if contains(.control) { result += "⌃" }
            if contains(.option) { result += "⌥" }
            if contains(.shift) { result += "⇧" }
            if contains(.command) { result += "⌘" }
            return result
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(Int.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    var keyCode: UInt16
    var modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds a shortcut from a key-down event. Returns nil for a bare modifier press.
    init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let code = event.keyCode
        guard !Self.modifierKeyCodes.contains(code) else { return nil }
        self.init(
            keyCode: code,
            modifiers: Modifiers(modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        )
    }

    /// True when the event's key and its ⌃⌥⇧⌘ subset match exactly. Caps lock, Fn,
    /// the numeric-pad bit, help and non-coalesced bits are ignored.
    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == Int64(self.keyCode) else { return false }
        return Modifiers(eventFlags: flags) == modifiers
    }

    /// Human-readable form, e.g. "⌃⌥R", "⌃⌥Space", "⌘F5".
    var displayString: String {
        modifiers.displayString + Self.keyName(for: keyCode)
    }

    /// A shortcut is only safe to claim globally when it carries ⌃, ⌥ or ⌘, or is a function key.
    var isUsableAsGlobalShortcut: Bool {
        if !modifiers.intersection([.control, .option, .command]).isEmpty { return true }
        return Self.functionKeyNumbers[keyCode] != nil
    }

    /// The `NSMenuItem.keyEquivalent` for this shortcut, or "" when it cannot be shown in a menu.
    var menuKeyEquivalent: String {
        if let number = Self.functionKeyNumbers[keyCode] {
            return String(UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(number - 1)) ?? " ")
        }
        if let scalar = Self.menuFunctionScalars[keyCode] {
            return String(UnicodeScalar(scalar) ?? " ")
        }
        if let literal = Self.menuLiterals[keyCode] { return literal }
        if Self.specialKeyNames[keyCode] != nil { return "" }
        return Self.printableName(for: keyCode)?.lowercased() ?? ""
    }

    var menuKeyEquivalentModifierMask: NSEvent.ModifierFlags {
        modifiers.modifierFlags
    }

    // MARK: - Key names

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static let functionKeyNumbers: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8,
        101: 9, 109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15,
        106: 16, 64: 17, 79: 18, 80: 19, 90: 20
    ]

    /// Keys that have no printable character of their own.
    private static let specialKeyNames: [UInt16: String] = {
        var names: [UInt16: String] = [
            49: "Space",
            36: "Return",
            76: "Enter",
            48: "Tab",
            51: "Delete",
            117: "Forward Delete",
            53: "Escape",
            114: "Help",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑",
            115: "Home",
            119: "End",
            116: "Page Up",
            121: "Page Down",
            71: "Keypad Clear",
            65: "Keypad .",
            67: "Keypad *",
            69: "Keypad +",
            75: "Keypad /",
            78: "Keypad −",
            81: "Keypad =",
            82: "Keypad 0",
            83: "Keypad 1",
            84: "Keypad 2",
            85: "Keypad 3",
            86: "Keypad 4",
            87: "Keypad 5",
            88: "Keypad 6",
            89: "Keypad 7",
            91: "Keypad 8",
            92: "Keypad 9"
        ]
        for (code, number) in functionKeyNumbers { names[code] = "F\(number)" }
        return names
    }()

    /// Menu key equivalents for keys that map to an `NS…FunctionKey` scalar.
    private static let menuFunctionScalars: [UInt16: UInt32] = [
        126: UInt32(NSUpArrowFunctionKey),
        125: UInt32(NSDownArrowFunctionKey),
        123: UInt32(NSLeftArrowFunctionKey),
        124: UInt32(NSRightArrowFunctionKey),
        115: UInt32(NSHomeFunctionKey),
        119: UInt32(NSEndFunctionKey),
        116: UInt32(NSPageUpFunctionKey),
        121: UInt32(NSPageDownFunctionKey),
        117: UInt32(NSDeleteFunctionKey),
        114: UInt32(NSHelpFunctionKey)
    ]

    private static let menuLiterals: [UInt16: String] = [
        49: " ",
        51: "\u{8}",
        36: "\r",
        76: "\r",
        48: "\t",
        53: "\u{1b}"
    ]

    /// Last-resort names for the standard ANSI layout, used when Carbon cannot answer.
    private static let ansiKeyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        50: "`"
    ]

    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let printable = printableName(for: keyCode) { return printable.uppercased() }
        if let ansi = ansiKeyNames[keyCode] { return ansi }
        return "Key \(keyCode)"
    }

    /// Asks the current keyboard layout what character a key produces with no modifiers.
    private static func printableName(for keyCode: UInt16) -> String? {
        guard specialKeyNames[keyCode] == nil else { return nil }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        guard let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var actualLength = 0
        let status: OSStatus = layoutData.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &actualLength,
                &characters
            )
        }
        guard status == noErr, actualLength > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: actualLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// How Quick Dictation push-to-talk is triggered.
enum DictationTrigger: Codable, Equatable, Sendable {
    case functionKey
    case keyboardShortcut(KeyboardShortcut)

    var title: String {
        switch self {
        case .functionKey: return "Hold Fn"
        case .keyboardShortcut(let shortcut): return "Hold \(shortcut.displayString)"
        }
    }

    var summary: String { title }

    var isFunctionKey: Bool {
        if case .functionKey = self { return true }
        return false
    }

    var shortcut: KeyboardShortcut? {
        if case .keyboardShortcut(let shortcut) = self { return shortcut }
        return nil
    }
}

/// The actions a user can bind a shortcut to.
enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case quickDictation
    case toggleLongDictation
    case toggleConversation
    case readSelectedText
    case pauseOrResumeReadback

    var title: String {
        switch self {
        case .quickDictation: return "Quick Dictation"
        case .toggleLongDictation: return "Long Dictation"
        case .toggleConversation: return "Conversation Transcript"
        case .readSelectedText: return "Read Selected Text"
        case .pauseOrResumeReadback: return "Pause or Resume Readback"
        }
    }

    var detail: String {
        switch self {
        case .quickDictation:
            return "Hold to dictate into the focused text field; release to insert."
        case .toggleLongDictation:
            return "Press once to start hands-free dictation, and press again to insert what you said."
        case .toggleConversation:
            return "Press once to start recording a conversation transcript, and press again to stop and save it."
        case .readSelectedText:
            return "Read the text you have selected in any app out loud."
        case .pauseOrResumeReadback:
            return "Pause the readback that is playing, or resume it where it stopped."
        }
    }
}

/// Every shortcut the app listens for, with the defaults it ships with.
struct ShortcutBindings: Codable, Equatable, Sendable {
    var quickDictation: DictationTrigger
    var toggleLongDictation: KeyboardShortcut?
    var toggleConversation: KeyboardShortcut?
    var readSelectedText: KeyboardShortcut?
    var pauseOrResumeReadback: KeyboardShortcut?

    static let bindingsKey = "shortcutBindings"
    static let legacyDictationShortcutKey = "dictationShortcut"

    static let standard = ShortcutBindings(
        quickDictation: .functionKey,
        toggleLongDictation: KeyboardShortcut(keyCode: 37, modifiers: [.control, .option]),
        toggleConversation: KeyboardShortcut(keyCode: 8, modifiers: [.control, .option]),
        readSelectedText: KeyboardShortcut(keyCode: 15, modifiers: [.control, .option]),
        pauseOrResumeReadback: KeyboardShortcut(keyCode: 35, modifiers: [.control, .option])
    )

    /// The ⌃⌥Space push-to-talk shortcut the old `controlOptionSpace` setting used.
    static let legacyControlOptionSpace = KeyboardShortcut(keyCode: 49, modifiers: [.control, .option])

    init(
        quickDictation: DictationTrigger = .functionKey,
        toggleLongDictation: KeyboardShortcut? = nil,
        toggleConversation: KeyboardShortcut? = nil,
        readSelectedText: KeyboardShortcut? = nil,
        pauseOrResumeReadback: KeyboardShortcut? = nil
    ) {
        self.quickDictation = quickDictation
        self.toggleLongDictation = toggleLongDictation
        self.toggleConversation = toggleConversation
        self.readSelectedText = readSelectedText
        self.pauseOrResumeReadback = pauseOrResumeReadback
    }

    private enum CodingKeys: String, CodingKey {
        case quickDictation, toggleLongDictation, toggleConversation, readSelectedText, pauseOrResumeReadback
    }

    /// Bindings saved before an action existed receive that action's default;
    /// a binding the user cleared is stored as an explicit null and stays cleared.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quickDictation = try container.decodeIfPresent(DictationTrigger.self, forKey: .quickDictation) ?? .functionKey
        toggleLongDictation = try Self.decodeOptional(container, .toggleLongDictation, fallback: Self.standard.toggleLongDictation)
        toggleConversation = try Self.decodeOptional(container, .toggleConversation, fallback: Self.standard.toggleConversation)
        readSelectedText = try Self.decodeOptional(container, .readSelectedText, fallback: Self.standard.readSelectedText)
        pauseOrResumeReadback = try Self.decodeOptional(container, .pauseOrResumeReadback, fallback: Self.standard.pauseOrResumeReadback)
    }

    private static func decodeOptional(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        fallback: KeyboardShortcut?
    ) throws -> KeyboardShortcut? {
        guard container.contains(key) else { return fallback }
        return try container.decodeIfPresent(KeyboardShortcut.self, forKey: key)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quickDictation, forKey: .quickDictation)
        try container.encode(toggleLongDictation, forKey: .toggleLongDictation)
        try container.encode(toggleConversation, forKey: .toggleConversation)
        try container.encode(readSelectedText, forKey: .readSelectedText)
        try container.encode(pauseOrResumeReadback, forKey: .pauseOrResumeReadback)
    }

    subscript(action: ShortcutAction) -> KeyboardShortcut? {
        get {
            switch action {
            case .quickDictation: return quickDictation.shortcut
            case .toggleLongDictation: return toggleLongDictation
            case .toggleConversation: return toggleConversation
            case .readSelectedText: return readSelectedText
            case .pauseOrResumeReadback: return pauseOrResumeReadback
            }
        }
        set {
            switch action {
            case .quickDictation:
                // Quick Dictation always has a trigger; clearing it is not allowed.
                guard let newValue else { return }
                quickDictation = .keyboardShortcut(newValue)
            case .toggleLongDictation: toggleLongDictation = newValue
            case .toggleConversation: toggleConversation = newValue
            case .readSelectedText: readSelectedText = newValue
            case .pauseOrResumeReadback: pauseOrResumeReadback = newValue
            }
        }
    }

    /// Pairs of actions that are bound to the very same key combination.
    func conflicts() -> [(ShortcutAction, ShortcutAction)] {
        let actions = ShortcutAction.allCases
        var result: [(ShortcutAction, ShortcutAction)] = []
        for (index, first) in actions.enumerated() {
            guard let firstShortcut = self[first] else { continue }
            for second in actions.dropFirst(index + 1) {
                guard let secondShortcut = self[second] else { continue }
                if firstShortcut == secondShortcut { result.append((first, second)) }
            }
        }
        return result
    }

    static func load(defaults: UserDefaults = .standard) -> ShortcutBindings {
        // The development TTS preview uses a separate defaults domain. If it has
        // never saved shortcuts, fall back to the production choices.
        let production = LocalDictationPreviewIdentity.isPreview()
            ? UserDefaults(suiteName: "org.localdictation.app")
            : nil
        let stored = defaults.data(forKey: bindingsKey) ?? production?.data(forKey: bindingsKey)
        if let stored, let decoded = try? JSONDecoder().decode(ShortcutBindings.self, from: stored) {
            return decoded
        }
        var bindings = ShortcutBindings.standard
        let legacy = defaults.string(forKey: legacyDictationShortcutKey)
            ?? production?.string(forKey: legacyDictationShortcutKey)
        if legacy == "controlOptionSpace" {
            bindings.quickDictation = .keyboardShortcut(legacyControlOptionSpace)
        }
        return bindings
    }

    func persist(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.bindingsKey)
    }
}
