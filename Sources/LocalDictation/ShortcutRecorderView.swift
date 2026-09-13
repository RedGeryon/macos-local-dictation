import AppKit

/// A compact "click, then type" shortcut recorder in the style of
/// System Settings › Keyboard. Click the field to start recording, press a key
/// combination to bind it, press Delete to clear, or press Escape to cancel.
@MainActor
final class ShortcutRecorderView: NSView {
    var shortcut: KeyboardShortcut? {
        didSet { updatePresentation() }
    }
    /// Called with the new binding, or nil when the user cleared it.
    var onChange: ((KeyboardShortcut?) -> Void)?
    /// Called when recording starts or ends, so the global event tap can be
    /// paused while the user types the new combination.
    var onRecordingStateChange: ((Bool) -> Void)?
    var placeholder = "Record Shortcut"
    var isEnabled = true {
        didSet {
            recordButton.isEnabled = isEnabled
            clearButton.isEnabled = isEnabled
            if !isEnabled { cancelRecording() }
        }
    }

    private(set) var isRecording = false
    private let recordButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var heldModifiers: KeyboardShortcut.Modifiers = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("ShortcutRecorderView is code-only") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Leaving the window ends any recording so the monitors are released.
        if newWindow == nil { cancelRecording() }
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.toolTip = "Remove this shortcut"
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recordButton)
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            recordButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            recordButton.topAnchor.constraint(equalTo: topAnchor),
            recordButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 256),
            clearButton.leadingAnchor.constraint(equalTo: recordButton.trailingAnchor, constant: 4),
            clearButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 20)
        ])
        updatePresentation()
    }

    override var acceptsFirstResponder: Bool { true }

    private func updatePresentation() {
        if isRecording {
            let held = heldModifiers.displayString
            recordButton.title = held.isEmpty ? "Type shortcut…" : "\(held)…"
            recordButton.contentTintColor = .controlAccentColor
            clearButton.isHidden = true
            recordButton.setAccessibilityLabel("Recording shortcut")
        } else if let shortcut {
            recordButton.title = shortcut.displayString
            recordButton.contentTintColor = nil
            clearButton.isHidden = false
            recordButton.setAccessibilityLabel("Shortcut \(shortcut.displayString)")
        } else {
            recordButton.title = placeholder
            recordButton.contentTintColor = .secondaryLabelColor
            clearButton.isHidden = true
            recordButton.setAccessibilityLabel(placeholder)
        }
    }

    @objc private func toggleRecording() {
        isRecording ? cancelRecording() : beginRecording()
    }

    @objc private func clear() {
        cancelRecording()
        shortcut = nil
        onChange?(nil)
    }

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        window?.makeFirstResponder(self)
        onRecordingStateChange?(true)
        // Local monitors run on the main thread. Only plain values cross into
        // the isolated closure so the compiler can verify the hop.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let type = event.type
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                self?.handle(type: type, keyCode: keyCode, flags: flags) ?? false
            }
            return consumed ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let location = event.locationInWindow
            let windowID = event.window.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = self.recordButton.convert(location, from: nil)
                let sameWindow = windowID == self.window.map(ObjectIdentifier.init)
                // A click on the field itself is handled by toggleRecording.
                if sameWindow, self.recordButton.bounds.contains(point) { return }
                self.cancelRecording()
            }
            return event
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.cancelRecording() }
            }
        }
        updatePresentation()
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        heldModifiers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        mouseMonitor = nil
        resignObserver = nil
        onRecordingStateChange?(false)
        updatePresentation()
    }

    /// Returns true when the event was consumed by the recorder.
    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = KeyboardShortcut.Modifiers(modifierFlags: flags.intersection(.deviceIndependentFlagsMask))
        switch type {
        case .flagsChanged:
            heldModifiers = modifiers
            updatePresentation()
            return true
        case .keyDown:
            if keyCode == 53 { // Escape
                cancelRecording()
                return true
            }
            if (keyCode == 51 || keyCode == 117), modifiers.isEmpty { // Delete / Forward Delete
                clear()
                return true
            }
            guard !Self.modifierKeyCodes.contains(keyCode) else { return true }
            let candidate = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
            guard candidate.isUsableAsGlobalShortcut else {
                recordButton.title = "Add ⌃, ⌥ or ⌘"
                NSSound.beep()
                return true
            }
            cancelRecording()
            shortcut = candidate
            onChange?(candidate)
            return true
        default:
            return false
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
}
