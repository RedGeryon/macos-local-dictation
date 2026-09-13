import AppKit
import Combine

private final class FlippedTextToSpeechPage: NSStackView {
    override var isFlipped: Bool { true }
}

private final class StandardEditingTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "v": paste(nil)
        case "x": cut(nil)
        case "z": undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

@MainActor
final class TextToSpeechWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private enum Page { case voice, audio }

    private weak var coordinator: AppCoordinator?
    private let tabs = NSSegmentedControl(labels: ["Voice", "Audio"], trackingMode: .selectOne, target: nil, action: nil)
    private let currentVoiceLabel = NSTextField(wrappingLabelWithString: "Current voice: Ryan")
    private let voicePopup = NSPopUpButton()
    private let promptLabel = NSTextField(labelWithString: "Delivery style")
    private let promptEditor = StandardEditingTextView()
    private let promptScroll = NSScrollView()
    private let pronunciationField = NSTextField()
    private let settingsDisclosure = NSButton(title: "More settings", target: nil, action: nil)
    private let settingsStack = NSStackView()
    private let audioEditor = StandardEditingTextView()
    private let audioScroll = NSScrollView()
    private let draftStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let voiceValidationLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Preparing text to speech…")
    private let setupDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton()
    private let accessibilityButton = NSButton()
    private let accessibilityHint = NSTextField(wrappingLabelWithString: "")
    private let pauseButton = NSButton()
    private let stopButton = NSButton()
    private let pageScroll = NSScrollView()
    private let voicePage = FlippedTextToSpeechPage()
    private let audioPage = FlippedTextToSpeechPage()
    private var selectedPage: Page = .voice
    private var draftIsDirty = false
    private var isRefreshing = false
    private var showingMoreSettings = false
    private var voiceValidationError: String?
    private var catalogSignature: [String] = []
    private var observation: AnyCancellable?
    private var savedSpeechStatus: String?
    private var isEmbedded = false
    private var pageScrollMinimumHeight: NSLayoutConstraint?
    private var rootInsets: [NSLayoutConstraint] = []
    private var embeddedPageHeight: NSLayoutConstraint?
    private let previewVoiceButton = NSButton()
    private let listenButton = NSButton()
    private let saveAudioButton = NSButton()

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Text to Speech"
        window.minSize = NSSize(width: 600, height: 620)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showAndActivate() {
        showVoicePage()
        NSApp.setActivationPolicy(.regular)
        installStandardEditorMenuIfNeeded()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startObserving()
    }

    /// Moves the existing voice/audio editor into the unified settings window.
    /// The controls deliberately remain owned by this controller so draft
    /// validation, playback controls, and the status refresh timer behave the
    /// same way whether Read Aloud is opened alone or from Settings.
    func makeEmbeddedContent() -> NSView {
        guard let content = window?.contentView else { return NSView() }
        isEmbedded = true
        if let root = content.subviews.first as? NSStackView,
           let titleRow = root.arrangedSubviews.first {
            titleRow.isHidden = true
        }
        pageScrollMinimumHeight?.isActive = false
        // The host page supplies its own padding.
        for constraint in rootInsets { constraint.constant = 0 }
        installSelectedPage()
        window?.contentView = NSView()
        startEmbedded()
        return content
    }

    func startEmbedded() {
        startObserving()
    }

    func stopEmbedded() {
        guard isEmbedded else { return }
        observation?.cancel()
        observation = nil
    }

    /// Refreshes whenever the coordinator publishes a change. The debounce
    /// coalesces bursts (streaming progress, voice list updates) into one pass.
    private func startObserving() {
        refresh()
        guard observation == nil, let coordinator else { return }
        observation = coordinator.objectWillChange
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    func showVoicePage() {
        selectedPage = .voice
        tabs.selectedSegment = 0
        installSelectedPage()
    }

    func showAudioPage() {
        selectedPage = .audio
        tabs.selectedSegment = 1
        installSelectedPage()
    }

    func showSavedSpeech(at url: URL) {
        savedSpeechStatus = "Saved \(url.lastPathComponent)"
        statusLabel.stringValue = savedSpeechStatus!
    }

    func windowWillClose(_ notification: Notification) {
        observation?.cancel()
        observation = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func installStandardEditorMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let menu = NSMenu()
        let appMenu = NSMenu(title: "Local Dictation")
        let appItem = NSMenuItem(title: "Local Dictation", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Local Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        rootInsets = [
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ]
        NSLayoutConstraint.activate(rootInsets)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.distribution = .fill
        let title = NSTextField(labelWithString: "Text to Speech")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        titleRow.addArrangedSubview(title)
        root.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        currentVoiceLabel.identifier = NSUserInterfaceItemIdentifier("tts.currentVoice")
        currentVoiceLabel.textColor = .secondaryLabelColor
        currentVoiceLabel.maximumNumberOfLines = 2
        root.addArrangedSubview(currentVoiceLabel)
        currentVoiceLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.identifier = NSUserInterfaceItemIdentifier("tts.tabs")
        root.addArrangedSubview(tabs)

        pageScroll.hasVerticalScroller = true
        pageScroll.autohidesScrollers = true
        pageScroll.scrollerStyle = .overlay
        pageScroll.borderType = .noBorder
        pageScroll.drawsBackground = false
        pageScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(pageScroll)
        pageScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        // The page itself scrolls, which keeps recovery and permission actions
        // reachable in the 600 × 620 minimum window.
        pageScrollMinimumHeight = pageScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        pageScrollMinimumHeight?.isActive = true
        configureVoicePage()
        configureAudioPage()
        installSelectedPage()

        statusLabel.identifier = NSUserInterfaceItemIdentifier("tts.status")
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        setupDetailLabel.identifier = NSUserInterfaceItemIdentifier("tts.setupDetail")
        setupDetailLabel.maximumNumberOfLines = 4
        setupDetailLabel.textColor = .secondaryLabelColor
        setupDetailLabel.isHidden = true
        root.addArrangedSubview(setupDetailLabel)
        setupDetailLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        retryButton.title = "Retry Text to Speech"
        retryButton.target = self
        retryButton.action = #selector(retryTextToSpeech)
        retryButton.identifier = NSUserInterfaceItemIdentifier("tts.retry")
        retryButton.isHidden = true
        root.addArrangedSubview(retryButton)

        accessibilityHint.identifier = NSUserInterfaceItemIdentifier("tts.shortcutsAccessibilityHint")
        accessibilityHint.stringValue = "Allow Accessibility to read selected text in other apps."
        accessibilityHint.textColor = .secondaryLabelColor
        accessibilityHint.isHidden = true
        root.addArrangedSubview(accessibilityHint)
        accessibilityHint.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        accessibilityButton.title = "Allow Accessibility to Read Selected Text…"
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        accessibilityButton.identifier = NSUserInterfaceItemIdentifier("tts.allowAccessibility")
        accessibilityButton.isHidden = true
        root.addArrangedSubview(accessibilityButton)

        let playbackControls = NSStackView()
        playbackControls.orientation = .horizontal
        playbackControls.spacing = 8
        pauseButton.title = "Pause"
        pauseButton.target = self
        pauseButton.action = #selector(pauseOrResume)
        pauseButton.identifier = NSUserInterfaceItemIdentifier("tts.pause")
        pauseButton.isHidden = true
        stopButton.title = "Stop"
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.identifier = NSUserInterfaceItemIdentifier("tts.stop")
        stopButton.isHidden = true
        stopButton.keyEquivalent = "\u{1b}"
        stopButton.keyEquivalentModifierMask = []
        playbackControls.addArrangedSubview(pauseButton)
        playbackControls.addArrangedSubview(stopButton)
        root.addArrangedSubview(playbackControls)
    }

    private func configureVoicePage() {
        configurePage(voicePage)
        let voiceRow = NSStackView()
        voiceRow.orientation = .horizontal
        voiceRow.alignment = .centerY
        voiceRow.spacing = 10
        let voiceLabel = NSTextField(labelWithString: "Voice")
        voiceLabel.setContentHuggingPriority(.required, for: .horizontal)
        voiceRow.addArrangedSubview(voiceLabel)
        voicePopup.identifier = NSUserInterfaceItemIdentifier("tts.voicePicker")
        voicePopup.target = self
        voicePopup.action = #selector(voiceChanged)
        voicePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        voiceRow.addArrangedSubview(voicePopup)
        voicePage.addArrangedSubview(voiceRow)
        voiceRow.widthAnchor.constraint(equalTo: voicePage.widthAnchor, constant: -4).isActive = true
        promptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        voicePage.addArrangedSubview(promptLabel)
        configureMultilineEditor(promptEditor, scroll: promptScroll, identifier: "tts.voicePrompt", minimumHeight: 78)
        promptEditor.delegate = self
        voicePage.addArrangedSubview(promptScroll)
        promptScroll.widthAnchor.constraint(equalTo: voicePage.widthAnchor, constant: -4).isActive = true
        draftStatusLabel.identifier = NSUserInterfaceItemIdentifier("tts.draftStatus")
        draftStatusLabel.maximumNumberOfLines = 2
        draftStatusLabel.textColor = .secondaryLabelColor
        voicePage.addArrangedSubview(draftStatusLabel)
        draftStatusLabel.widthAnchor.constraint(equalTo: voicePage.widthAnchor, constant: -4).isActive = true
        voiceValidationLabel.identifier = NSUserInterfaceItemIdentifier("tts.voiceValidation")
        voiceValidationLabel.maximumNumberOfLines = 2
        voiceValidationLabel.textColor = .systemRed
        voicePage.addArrangedSubview(voiceValidationLabel)
        voiceValidationLabel.widthAnchor.constraint(equalTo: voicePage.widthAnchor, constant: -4).isActive = true
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        previewVoiceButton.title = "Preview Voice"
        previewVoiceButton.target = self
        previewVoiceButton.action = #selector(previewVoice)
        previewVoiceButton.bezelStyle = .rounded
        previewVoiceButton.identifier = NSUserInterfaceItemIdentifier("tts.Preview Voice")
        actions.addArrangedSubview(previewVoiceButton)
        let save = button("Save & Use Voice", #selector(saveVoice), identifier: "tts.Save & Use Voice")
        save.bezelColor = .controlAccentColor
        actions.addArrangedSubview(save)
        voicePage.addArrangedSubview(actions)
        settingsDisclosure.setButtonType(.onOff)
        settingsDisclosure.isBordered = false
        settingsDisclosure.title = "More Options"
        settingsDisclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        settingsDisclosure.imagePosition = .imageLeading
        settingsDisclosure.setContentHuggingPriority(.required, for: .horizontal)
        settingsDisclosure.target = self
        settingsDisclosure.action = #selector(toggleSettings)
        settingsDisclosure.identifier = NSUserInterfaceItemIdentifier("tts.settingsDisclosure")
        voicePage.addArrangedSubview(settingsDisclosure)
        configureSettingsStack()
        voicePage.addArrangedSubview(settingsStack)
        settingsStack.widthAnchor.constraint(equalTo: voicePage.widthAnchor, constant: -4).isActive = true
    }

    private func configureSettingsStack() {
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 7
        let pronunciationLabel = NSTextField(labelWithString: "Pronunciations (for example: Qwen = kwen)")
        pronunciationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        settingsStack.addArrangedSubview(pronunciationLabel)
        pronunciationField.identifier = NSUserInterfaceItemIdentifier("tts.pronunciations")
        pronunciationField.placeholderString = "Optional; separate entries with commas or lines"
        pronunciationField.delegate = self
        settingsStack.addArrangedSubview(pronunciationField)
        pronunciationField.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true
        let shortcutsHint = NSTextField(wrappingLabelWithString: "Keyboard shortcuts for reading and pausing are set in Settings › Shortcuts.")
        shortcutsHint.textColor = .secondaryLabelColor
        settingsStack.addArrangedSubview(shortcutsHint)
        shortcutsHint.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true
        settingsStack.addArrangedSubview(button("Open Audio Folder", #selector(openAudioFolder), identifier: "tts.openAudioFolder"))
        settingsStack.addArrangedSubview(button("Open Saved Voices", #selector(openSavedVoices), identifier: "tts.openSavedVoices"))
    }

    private func configureAudioPage() {
        configurePage(audioPage)
        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.distribution = .fill
        top.addArrangedSubview(sectionTitle("Create audio"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.addArrangedSubview(spacer)
        let changeVoice = button("Change voice", #selector(changeVoice), identifier: "tts.changeVoice")
        changeVoice.isBordered = false
        changeVoice.contentTintColor = .linkColor
        changeVoice.setContentHuggingPriority(.required, for: .horizontal)
        top.addArrangedSubview(changeVoice)
        audioPage.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: audioPage.widthAnchor, constant: -4).isActive = true
        let help = NSTextField(wrappingLabelWithString: "Paste or type the text you want to hear. Audio uses the saved current voice; save voice changes before listening or exporting.")
        help.textColor = .secondaryLabelColor
        audioPage.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: audioPage.widthAnchor, constant: -4).isActive = true
        configureMultilineEditor(audioEditor, scroll: audioScroll, identifier: "tts.editor", minimumHeight: 270)
        audioEditor.font = .systemFont(ofSize: 14)
        audioEditor.isRichText = false
        audioEditor.delegate = self
        audioPage.addArrangedSubview(audioScroll)
        audioScroll.widthAnchor.constraint(equalTo: audioPage.widthAnchor, constant: -4).isActive = true
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        listenButton.title = "Listen"
        listenButton.target = self
        listenButton.action = #selector(listenToAudio)
        listenButton.bezelStyle = .rounded
        listenButton.identifier = NSUserInterfaceItemIdentifier("tts.Listen")
        actions.addArrangedSubview(listenButton)
        saveAudioButton.title = "Save Audio…"
        saveAudioButton.target = self
        saveAudioButton.action = #selector(generateAndSave)
        saveAudioButton.bezelStyle = .rounded
        saveAudioButton.bezelColor = .controlAccentColor
        saveAudioButton.identifier = NSUserInterfaceItemIdentifier("tts.Save Audio…")
        actions.addArrangedSubview(saveAudioButton)
        audioPage.addArrangedSubview(actions)
    }

    private func configurePage(_ page: NSStackView) {
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 9
        page.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 8, right: 2)
        page.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureMultilineEditor(_ editor: NSTextView, scroll: NSScrollView, identifier: String, minimumHeight: CGFloat) {
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.identifier = NSUserInterfaceItemIdentifier(identifier)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.font = .systemFont(ofSize: 13)
        scroll.documentView = editor
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
    }

    private func installSelectedPage() {
        let page = selectedPage == .voice ? voicePage : audioPage
        if pageScroll.documentView !== page {
            pageScroll.documentView = page
            page.widthAnchor.constraint(equalTo: pageScroll.contentView.widthAnchor).isActive = true
        }
        embeddedPageHeight?.isActive = false
        if isEmbedded {
            let height = pageScroll.heightAnchor.constraint(equalTo: page.heightAnchor)
            height.priority = .required
            height.isActive = true
            embeddedPageHeight = height
        }
        pageScroll.contentView.scroll(to: .zero)
        pageScroll.reflectScrolledClipView(pageScroll.contentView)
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func button(_ title: String, _ action: Selector, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        return button
    }

    private func refresh() {
        guard let coordinator else { return }
        isRefreshing = true
        rebuildVoicePickerIfNeeded(coordinator: coordinator)
        currentVoiceLabel.stringValue = "Current voice: \(voiceTitle(coordinator.textToSpeechSettings.activeVoiceConfiguration.voiceID, coordinator: coordinator))"
        // Draft changes are mirrored into the coordinator as the user types.
        // Assigning only changed values below preserves the active editor's
        // caret and undo history while still letting menu voice switches and
        // saved-profile picker changes resync the controls.
        loadDraftIntoControls(coordinator.textToSpeechDraft)
        draftIsDirty = coordinator.textToSpeechDraft != coordinator.textToSpeechSettings.activeVoiceConfiguration
        updatePromptPresentation()
        updateStatus(coordinator: coordinator)
        isRefreshing = false
    }

    private func rebuildVoicePickerIfNeeded(coordinator: AppCoordinator) {
        let available = coordinator.textToSpeechVoices.filter { $0.id != "voice-design" && $0.id != "voice-design-consistent" }
        let primary = TextToSpeechVoice.primaryVoiceIDs.map { id in
            available.first(where: { $0.id == id }) ?? TextToSpeechVoice.placeholder(id: id)
        }
        let secondary = available
            .filter { !TextToSpeechVoice.primaryVoiceIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let ids = primary.map(\.id) + ["voice-design-consistent"] + secondary.map(\.id)
        guard ids != catalogSignature else { return }
        catalogSignature = ids
        voicePopup.removeAllItems()
        for voice in primary {
            voicePopup.addItem(withTitle: voice.name)
            voicePopup.lastItem?.representedObject = voice.id
        }
        voicePopup.addItem(withTitle: "Custom voice")
        voicePopup.lastItem?.representedObject = "voice-design-consistent"
        if !secondary.isEmpty { voicePopup.menu?.addItem(.separator()) }
        for voice in secondary {
            voicePopup.addItem(withTitle: voice.name)
            voicePopup.lastItem?.representedObject = voice.id
        }
    }

    private func loadDraftIntoControls(_ draft: TextToSpeechVoiceConfiguration) {
        let selectedID = draft.voiceID == "voice-design" ? "voice-design-consistent" : draft.voiceID
        if let item = voicePopup.itemArray.first(where: { ($0.representedObject as? String) == selectedID }) { voicePopup.select(item) }
        // Timer refreshes must not reset an active editor's selection, undo
        // history, or insertion point when the displayed value is unchanged.
        if promptEditor.string != draft.voicePrompt { promptEditor.string = draft.voicePrompt }
        if pronunciationField.stringValue != draft.pronunciationOverridesText {
            pronunciationField.stringValue = draft.pronunciationOverridesText
        }
    }

    private func updatePromptPresentation() {
        switch selectedVoiceID {
        case "designed-narrator":
            promptLabel.stringValue = "Voice description"
            promptEditor.string = "This saved narrator voice has a fixed identity."
            promptEditor.isEditable = false
        case "voice-design-consistent":
            promptLabel.stringValue = "Voice description"
            promptEditor.isEditable = true
        default:
            promptLabel.stringValue = "Delivery style"
            promptEditor.isEditable = true
        }
        if let coordinator {
            draftStatusLabel.stringValue = draftIsDirty || coordinator.textToSpeechDraft != coordinator.textToSpeechSettings.activeVoiceConfiguration
                ? "Unsaved changes. Preview uses this draft; reading and audio exports use the saved current voice."
                : "Saved as your current voice."
        }
        voiceValidationLabel.stringValue = voiceValidationError ?? ""
        voiceValidationLabel.isHidden = voiceValidationError == nil
        settingsStack.isHidden = !showingMoreSettings
        settingsDisclosure.state = showingMoreSettings ? .on : .off
        settingsDisclosure.title = "More Options"
        settingsDisclosure.image = NSImage(systemSymbolName: showingMoreSettings ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    }

    private func updateStatus(coordinator: AppCoordinator) {
        if coordinator.textToSpeechState.isActive { savedSpeechStatus = nil }
        switch coordinator.textToSpeechState {
        case .unavailable(let message), .error(let message):
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
            setupDetailLabel.stringValue = coordinator.textToSpeechSetupGuidance
            setupDetailLabel.isHidden = false
            retryButton.isHidden = false
        default:
            if let savedSpeechStatus, case .ready = coordinator.textToSpeechState {
                statusLabel.stringValue = savedSpeechStatus
            } else if case .generating = coordinator.textToSpeechState, let progress = coordinator.textToSpeechProgress {
                statusLabel.stringValue = "Generating audio… \(Int(progress * 100))%"
            } else if case .generating = coordinator.textToSpeechState, !coordinator.textToSpeechProgressDetail.isEmpty {
                statusLabel.stringValue = "Generating audio… \(coordinator.textToSpeechProgressDetail)"
            } else {
                statusLabel.stringValue = coordinator.textToSpeechStatusLabel
            }
            statusLabel.textColor = .secondaryLabelColor
            setupDetailLabel.isHidden = true
            retryButton.isHidden = true
        }
        let active = coordinator.isTextToSpeechOperationActive
        previewVoiceButton.isEnabled = !active
        let hasAudioText = !audioEditor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        listenButton.isEnabled = !active && hasAudioText
        saveAudioButton.isEnabled = !active && hasAudioText
        pauseButton.isHidden = !active
        stopButton.isHidden = !active
        if case .speaking(let paused) = coordinator.textToSpeechState {
            pauseButton.isHidden = false
            pauseButton.title = paused ? "Resume" : "Pause"
        } else {
            pauseButton.isHidden = true
        }
        let needsAccessibility = !coordinator.accessibilityGrantedForSelectedText
        accessibilityHint.isHidden = !needsAccessibility
        accessibilityButton.isHidden = !needsAccessibility
    }

    private var selectedVoiceID: String { (voicePopup.selectedItem?.representedObject as? String) ?? "ryan" }

    private func syncDraftFromControls() {
        guard !isRefreshing else { return }
        let prompt = selectedVoiceID == "designed-narrator" ? "" : promptEditor.string
        coordinator?.updateTextToSpeechDraft(id: selectedVoiceID, voicePrompt: prompt, pronunciationOverridesText: pronunciationField.stringValue)
        draftIsDirty = coordinator?.textToSpeechDraft != coordinator?.textToSpeechSettings.activeVoiceConfiguration
        voiceValidationError = nil
        updatePromptPresentation()
    }

    private func validateDraftForVoiceAction() -> Bool {
        syncDraftFromControls()
        guard selectedVoiceID != "voice-design-consistent" || !promptEditor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            voiceValidationError = "Describe the custom narrator voice before previewing or saving it."
            updatePromptPresentation()
            return false
        }
        return true
    }

    private func voiceTitle(_ id: String, coordinator: AppCoordinator) -> String {
        switch id {
        case "voice-design", "voice-design-consistent": return "Custom voice"
        default: return coordinator.textToSpeechVoices.first(where: { $0.id == id })?.name ?? TextToSpeechVoice.placeholder(id: id).name
        }
    }

    @objc private func selectTab() { selectedPage = tabs.selectedSegment == 1 ? .audio : .voice; installSelectedPage() }
    @objc private func voiceChanged() {
        coordinator?.selectTextToSpeechDraftVoice(selectedVoiceID)
        draftIsDirty = coordinator?.textToSpeechDraft != coordinator?.textToSpeechSettings.activeVoiceConfiguration
        voiceValidationError = nil
        refresh()
    }
    @objc private func previewVoice() {
        guard validateDraftForVoiceAction() else { return }
        savedSpeechStatus = nil
        coordinator?.previewTextToSpeechDraft()
    }
    @objc private func saveVoice() {
        guard validateDraftForVoiceAction() else { return }
        do {
            try coordinator?.saveTextToSpeechDraftAsCurrentVoice()
            draftIsDirty = false
            voiceValidationError = nil
            refresh()
        } catch {
            voiceValidationError = error.localizedDescription
            updatePromptPresentation()
        }
    }
    @objc private func changeVoice() { showVoicePage() }
    @objc private func listenToAudio() { savedSpeechStatus = nil; coordinator?.previewTextToSpeechSavedVoice(text: audioEditor.string) }
    @objc private func generateAndSave() { savedSpeechStatus = nil; coordinator?.generateSpeechAudio(text: audioEditor.string, format: .rf64) }
    @objc private func pauseOrResume() { coordinator?.pauseOrResumeTextToSpeech() }
    @objc private func stop() { coordinator?.cancelTextToSpeech() }
    @objc private func retryTextToSpeech() { coordinator?.retryTextToSpeechSetup() }
    @objc private func requestAccessibility() { coordinator?.enableTextToSpeechReadShortcuts() }
    @objc private func openAudioFolder() { coordinator?.openGeneratedSpeechFolder() }
    @objc private func openSavedVoices() { coordinator?.openSavedVoicesFolder() }
    @objc private func toggleSettings() { showingMoreSettings.toggle(); updatePromptPresentation() }
    func controlTextDidChange(_ obj: Notification) { syncDraftFromControls() }
    func textDidChange(_ notification: Notification) {
        if notification.object as? NSTextView === promptEditor {
            syncDraftFromControls()
        } else if notification.object as? NSTextView === audioEditor {
            if let coordinator { updateStatus(coordinator: coordinator) }
        }
    }
}
