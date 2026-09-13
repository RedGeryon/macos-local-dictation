import AppKit
import Combine

private final class FlippedUnifiedDocumentView: NSView { override var isFlipped: Bool { true } }

/// The single Settings window: a source-list sidebar and one scrolling detail
/// page. Pages are rebuilt from coordinator state when something they show
/// changes; the coordinator is observed rather than polled.
@MainActor
final class UnifiedLocalDictationWindowController: NSWindowController {
    enum Page: Int, CaseIterable {
        case speechToText, textToSpeech, shortcuts, models

        var title: String {
            switch self {
            case .speechToText: return "Speech to Text"
            case .textToSpeech: return "Text to Speech"
            case .shortcuts: return "Shortcuts"
            case .models: return "Models & Startup"
            }
        }

        var symbolName: String {
            switch self {
            case .speechToText: return "mic.fill"
            case .textToSpeech: return "speaker.wave.2.fill"
            case .shortcuts: return "keyboard"
            case .models: return "square.stack.3d.up.fill"
            }
        }
    }

    private enum Layout {
        static let sidebarWidth: CGFloat = 200
        static let pageInset: CGFloat = 28
        static let sectionSpacing: CGFloat = 22
        static let groupInset: CGFloat = 14
        static let formLabelWidth: CGFloat = 176
        static let controlWidth: CGFloat = 280
        static let minimumSize = NSSize(width: 820, height: 600)
        static let initialSize = NSSize(width: 920, height: 680)
    }

    private let coordinator: AppCoordinator
    private let sidebar = NSTableView()
    private let sidebarScroll = NSScrollView()
    private let scroll = NSScrollView()
    private let content = FlippedUnifiedDocumentView()
    private var page = Page.speechToText
    private var tts: TextToSpeechWindowController?
    private var embeddedTTSContent: NSView?
    private var renderedFingerprint = ""
    private var showingCustomVoiceDownloads = false
    private var catalogPopover: NSPopover?
    private var observation: AnyCancellable?
    private var activationObserver: NSObjectProtocol?
    private var hasShownOnce = false
    private var isRecordingShortcut = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Local Dictation"
        window.minSize = Layout.minimumSize
        window.contentMinSize = Layout.minimumSize
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError("UnifiedLocalDictationWindowController is code-only") }

    func showAndActivate() {
        guard let window else { return }
        if !hasShownOnce {
            hasShownOnce = true
            window.setFrameAutosaveName("LocalDictation.Settings")
            if !window.setFrameUsingName("LocalDictation.Settings") {
                window.setContentSize(Layout.initialSize)
                window.center()
            }
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        startObserving()
        refresh()
    }

    // MARK: - Observation

    private func startObserving() {
        guard observation == nil else { return }
        observation = coordinator.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Returning from System Settings is the moment permissions change.
            Task { @MainActor in
                self?.coordinator.refreshPermissions()
                self?.refresh()
            }
        }
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        tts?.stopEmbedded()
    }

    private func refresh() {
        guard window?.isVisible == true else { return }
        guard page != .textToSpeech else { return } // The embedded editor observes on its own.
        let fingerprint = fingerprint(for: page)
        guard fingerprint != renderedFingerprint else { return }
        // Never replace a control while the user is typing in it or recording a shortcut.
        guard !(window?.firstResponder is NSTextView), !isRecordingShortcut else { return }
        render(page, preserveScroll: true)
    }

    private func fingerprint(for page: Page) -> String {
        switch page {
        case .speechToText:
            return [
                "\(coordinator.state)", "\(coordinator.dictationEngineStatus)", "\(coordinator.localFeatureSettings.dictation)",
                "\(coordinator.settings)", "\(coordinator.configuration)", "\(coordinator.permissionStatus)",
                "\(coordinator.microphonePermissionState)", "\(coordinator.systemAudioPermissionState)", "\(coordinator.systemAudioAllowedInSystemSettings)",
                "\(coordinator.globalShortcutOperational)", "\(coordinator.canTranscribeMediaFile)",
                "\(coordinator.isTextToSpeechOperationActive)", "\(coordinator.isTextToSpeechPreview)"
            ].joined(separator: "|")
        case .textToSpeech:
            return ""
        case .shortcuts:
            return [
                "\(coordinator.settings.bindings)", "\(coordinator.textToSpeechSettings.shortcutsEnabled)",
                "\(coordinator.permissionStatus.accessibility)", "\(coordinator.globalShortcutOperational)",
                "\(coordinator.localFeatureSettings)"
            ].joined(separator: "|")
        case .models:
            let detail = coordinator.dictationEngineStatusDetail ?? ""
            return [
                "\(coordinator.localFeatureSettings)", coordinator.configuration.modelURL.path, "\(coordinator.installedSpeechModels)",
                "\(coordinator.installedTextToSpeechFamilies)", "\(coordinator.dictationEngineStatus)", detail,
                "\(coordinator.isDictationEngineUnloading)", "\(coordinator.readAloudEngineStatus)", "\(coordinator.modelDownloadState)",
                "\(coordinator.textToSpeechInstallState)", "\(coordinator.textToSpeechModelInstallStatus)",
                coordinator.textToSpeechInstallDetail, "\(coordinator.canEditSpeechConfiguration)",
                "\(coordinator.isTextToSpeechOperationActive)", "\(coordinator.state)", "\(coordinator.textToSpeechState)",
                "\(showingCustomVoiceDownloads)", "\(coordinator.loginItemState)"
            ].joined(separator: "|")
        }
    }

    // MARK: - Window structure

    private func build() {
        guard let root = window?.contentView else { return }
        sidebar.headerView = nil
        sidebar.delegate = self
        sidebar.dataSource = self
        sidebar.style = .sourceList
        sidebar.rowHeight = 30
        sidebar.addTableColumn(NSTableColumn(identifier: .init("nav")))
        sidebar.identifier = NSUserInterfaceItemIdentifier("unified.sidebar")
        sidebar.setAccessibilityLabel("Settings pages")
        sidebarScroll.identifier = NSUserInterfaceItemIdentifier("unified.sidebarScroll")
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        let sidebarBackground = NSVisualEffectView()
        sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .behindWindow
        sidebarBackground.state = .followsWindowActiveState
        sidebarBackground.translatesAutoresizingMaskIntoConstraints = false
        sidebarBackground.addSubview(sidebarScroll)

        scroll.identifier = NSUserInterfaceItemIdentifier("unified.detailScroll")
        content.identifier = NSUserInterfaceItemIdentifier("unified.content")
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebarBackground)
        root.addSubview(divider)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            sidebarBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarBackground.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarBackground.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarBackground.topAnchor, constant: 12),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        render(.speechToText)
    }

    private func render(_ newPage: Page, preserveScroll: Bool = false) {
        if page == .textToSpeech, newPage != .textToSpeech { tts?.stopEmbedded() }
        page = newPage
        catalogPopover?.close()
        content.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch newPage {
        case .speechToText: view = speechToTextPage()
        case .textToSpeech: view = textToSpeechPage()
        case .shortcuts: view = shortcutsPage()
        case .models: view = modelsPage()
        }
        renderedFingerprint = fingerprint(for: newPage)
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Layout.pageInset),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Layout.pageInset),
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: Layout.pageInset),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Layout.pageInset)
        ])
        if !preserveScroll {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func select(_ newPage: Page) {
        sidebar.selectRowIndexes(IndexSet(integer: newPage.rawValue), byExtendingSelection: false)
        if page != newPage || content.subviews.isEmpty { render(newPage) }
    }

    // MARK: - Speech to Text page

    private func speechToTextPage() -> NSView {
        let pageStack = pageContainer(
            "Speech to Text",
            "Dictate into any app, transcribe a two-sided conversation, or turn an audio or video file into text. Recognition runs on this Mac."
        )
        let enabled = coordinator.localFeatureSettings.dictation.enabled
        let engineReady = coordinator.dictationEngineStatus == .ready
        let presentation = FeatureStatusPresentation.speechToText(
            state: coordinator.state,
            engine: coordinator.dictationEngineStatus,
            enabled: enabled
        )

        // Status
        let statusGroup = groupStack()
        let statusRow = statusLine(presentation)
        let statusAction: NSButton?
        if !enabled {
            statusAction = button("Enable in Models & Startup…", #selector(showModels), id: "dictation.models")
        } else if case .permissionRequired = coordinator.state {
            statusAction = nil
        } else if coordinator.dictationEngineStatus == .notLoaded || coordinator.dictationEngineStatus == .loading {
            let load = button(coordinator.dictationEngineStatus == .loading ? "Loading…" : "Load Speech Model", #selector(loadDictation), id: "dictation.load")
            load.isEnabled = coordinator.dictationEngineStatus == .notLoaded
            statusAction = load
        } else if !engineReady {
            statusAction = button("Open Models & Startup…", #selector(showModels), id: "dictation.models")
        } else {
            statusAction = nil
        }
        addFullWidth(spread(statusRow, trailing: statusAction), to: statusGroup)
        let hint = wrappingLabel(shortcutSummary(), secondary: true)
        hint.identifier = NSUserInterfaceItemIdentifier("dictation.shortcutHint")
        addFullWidth(spread(hint, trailing: linkButton("Change Shortcuts…", #selector(showShortcuts))), to: statusGroup)
        add(section("Status", statusGroup), to: pageStack)

        // Actions
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        let available = enabled && engineReady && !coordinator.isTextToSpeechOperationActive
        let conversation = button("Start Conversation Transcript", #selector(toggleConversation), id: "dictation.conversation")
        conversation.isEnabled = available
        let file = button("Transcribe Audio or Video File…", #selector(transcribeFile), id: "dictation.file")
        file.isEnabled = available && coordinator.canTranscribeMediaFile
        let transcripts = button("Open Transcripts Folder", #selector(openTranscriptsFolder), id: "dictation.transcripts")
        actions.addArrangedSubview(conversation)
        actions.addArrangedSubview(file)
        actions.addArrangedSubview(transcripts)
        let actionsGroup = groupStack()
        actionsGroup.addArrangedSubview(actions)
        actionsGroup.addArrangedSubview(wrappingLabel(
            "Conversation transcripts record you and the Mac speaker as separate lines. Transcripts are saved in Documents › Local Dictation Transcripts.",
            secondary: true
        ))
        add(section("Actions", actionsGroup), to: pageStack)

        // Preferences
        let language = NSPopUpButton()
        language.addItems(withTitles: RecognitionLanguage.allCases.map(\.title))
        language.selectItem(at: RecognitionLanguage.allCases.firstIndex(of: coordinator.configuration.recognitionLanguage) ?? 0)
        language.target = self
        language.action = #selector(changeLanguage(_:))
        language.isEnabled = coordinator.configuration.modelVariant.supportsLanguageSelection
        language.identifier = NSUserInterfaceItemIdentifier("dictation.language")
        language.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true
        language.toolTip = coordinator.configuration.modelVariant.supportsLanguageSelection
            ? "Applies to quick dictation, conversations, and file transcription."
            : "The English model transcribes English only. Add the multilingual model in Models & Startup to choose other languages."
        let punctuation = checkbox("Add punctuation automatically", coordinator.settings.automaticPunctuation, #selector(togglePunctuation(_:)), id: "dictation.punctuation")
        let live = checkbox("Show the live transcript while dictating", coordinator.settings.showLivePreview, #selector(toggleLive(_:)), id: "dictation.livePreview")
        let fillers = checkbox("Remove filler words such as “um” and “uh”", coordinator.settings.removeFillers, #selector(toggleFillers(_:)), id: "dictation.fillers")
        let form = formGrid([
            ("Language:", language),
            ("Punctuation:", punctuation),
            ("Overlay:", live),
            ("Cleanup:", fillers)
        ])
        let preferencesGroup = groupStack()
        preferencesGroup.addArrangedSubview(form)
        if !coordinator.configuration.modelVariant.supportsLanguageSelection {
            preferencesGroup.addArrangedSubview(wrappingLabel("The English model transcribes English only. Add the multilingual model in Models & Startup to choose other languages.", secondary: true))
        }
        add(section("Preferences", preferencesGroup), to: pageStack)

        // Permissions
        let permissionsGroup = groupStack()
        permissionsGroup.spacing = 12
        if coordinator.isTextToSpeechPreview {
            permissionsGroup.addArrangedSubview(wrappingLabel("macOS lists this preview as “Local Dictation TTS Preview.” Permissions for the installed app are separate.", secondary: true))
        }
        let micNeedsSettings = coordinator.microphonePermissionState.needsSettings
        addFullWidth(permissionRow(
            "Microphone",
            detail: "Captures speech only while dictation or a conversation transcript is active.",
            granted: coordinator.permissionStatus.microphone,
            actionTitle: micNeedsSettings ? "Open System Settings…" : "Allow…",
            action: micNeedsSettings ? #selector(openMicSettings) : #selector(requestMic),
            id: "dictation.microphone"
        ), to: permissionsGroup)
        let accessibilityDetail: String
        if coordinator.permissionStatus.accessibility && !coordinator.globalShortcutOperational {
            accessibilityDetail = "Allowed, but the global shortcut is not active yet. This page checks again when you return from System Settings."
        } else {
            accessibilityDetail = "Needed for global shortcuts, inserting text at the cursor, and reading selected text."
        }
        addFullWidth(permissionRow(
            "Accessibility",
            detail: accessibilityDetail,
            granted: coordinator.permissionStatus.accessibility,
            actionTitle: "Allow…",
            action: #selector(requestAccessibility),
            id: "dictation.accessibility"
        ), to: permissionsGroup)
        let systemAudioAllowed = coordinator.systemAudioPermissionState == .verifiedCurrentCapture
            || coordinator.systemAudioAllowedInSystemSettings
        addFullWidth(permissionRow(
            "Screen & System Audio Recording",
            detail: systemAudioAllowed
                ? "Used only for conversation transcripts. Only audio is captured; no screen video is recorded."
                : "Optional. Needed only for conversation transcripts; macOS asks for it when one starts. Quick dictation never needs it.",
            state: systemAudioAllowed ? .allowed : .notAllowed,
            actionTitle: "Open System Settings…",
            action: #selector(openSystemAudioSettings),
            id: "dictation.systemAudioSettings",
            showsAction: !systemAudioAllowed
        ), to: permissionsGroup)
        add(section("Permissions", permissionsGroup), to: pageStack)
        return pageStack
    }

    private func shortcutSummary() -> String {
        let bindings = coordinator.settings.bindings
        guard coordinator.localFeatureSettings.dictation.enabled else {
            return "Quick dictation is off until Speech to Text is enabled in Models & Startup."
        }
        var parts = ["\(bindings.quickDictation.title) in any app to dictate."]
        if let conversation = bindings.toggleConversation {
            parts.append("\(conversation.displayString) starts or stops a conversation transcript.")
        }
        parts.append("Escape cancels.")
        return parts.joined(separator: " ")
    }

    // MARK: - Text to Speech page

    private func textToSpeechPage() -> NSView {
        let pageStack = pageContainer(
            "Text to Speech",
            "Choose and tune the voice used to read text aloud, then listen to or export audio from any text. Preview uses the draft; readback and audio files use the saved voice."
        )
        let controller: TextToSpeechWindowController
        if let tts {
            controller = tts
        } else {
            controller = TextToSpeechWindowController(coordinator: coordinator)
            tts = controller
        }
        let embedded: NSView
        if let embeddedTTSContent {
            embedded = embeddedTTSContent
        } else {
            embedded = controller.makeEmbeddedContent()
            embeddedTTSContent = embedded
        }
        controller.startEmbedded()
        embedded.removeFromSuperview()
        embedded.translatesAutoresizingMaskIntoConstraints = false
        add(section("Voice and Audio", embedded), to: pageStack)
        return pageStack
    }

    // MARK: - Shortcuts page

    private func shortcutsPage() -> NSView {
        let pageStack = pageContainer(
            "Shortcuts",
            "Shortcuts work in every app. Click a field, then press the keys you want. Press Delete to remove a shortcut or Escape to keep the current one."
        )
        let bindings = coordinator.settings.bindings

        if !coordinator.permissionStatus.accessibility {
            let notice = groupStack()
            addFullWidth(permissionRow(
                "Accessibility",
                detail: "Global shortcuts need Accessibility permission before they work outside this window.",
                granted: false,
                actionTitle: "Allow…",
                action: #selector(requestAccessibility),
                id: "shortcuts.accessibility"
            ), to: notice)
            add(section("Permission", notice), to: pageStack)
        }

        // Speech to Text shortcuts
        let triggerRow = NSStackView()
        triggerRow.orientation = .horizontal
        triggerRow.alignment = .centerY
        triggerRow.spacing = 8
        let triggerPopup = NSPopUpButton()
        triggerPopup.addItem(withTitle: "Hold the Fn key")
        triggerPopup.addItem(withTitle: "Hold a key combination")
        triggerPopup.selectItem(at: bindings.quickDictation.isFunctionKey ? 0 : 1)
        triggerPopup.target = self
        triggerPopup.action = #selector(changeQuickDictationTrigger(_:))
        triggerPopup.identifier = NSUserInterfaceItemIdentifier("shortcuts.quickDictationMode")
        triggerPopup.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true
        triggerRow.addArrangedSubview(triggerPopup)
        if case .keyboardShortcut(let shortcut) = bindings.quickDictation {
            let recorder = recorder(for: .quickDictation, shortcut: shortcut)
            triggerRow.addArrangedSubview(recorder)
        }
        let longDictation = recorder(for: .toggleLongDictation, shortcut: bindings.toggleLongDictation)
        let conversation = recorder(for: .toggleConversation, shortcut: bindings.toggleConversation)
        let sttForm = formGrid([
            ("Quick Dictation:", triggerRow),
            ("Long Dictation:", longDictation),
            ("Conversation Transcript:", conversation)
        ])
        let sttGroup = groupStack()
        sttGroup.addArrangedSubview(sttForm)
        let dictationHelp = bindings.quickDictation.isFunctionKey
            ? "Hold Fn and speak; release to insert the text. Long Dictation is hands-free: press its shortcut (or Space while holding Fn) to start, and again to insert."
            : "Hold the combination and speak; release the key to insert the text. Long Dictation is hands-free: press its shortcut to start, and again to insert."
        sttGroup.addArrangedSubview(wrappingLabel(dictationHelp, secondary: true))
        add(section("Speech to Text", sttGroup), to: pageStack)

        // Text to Speech shortcuts
        let ttsEnabled = coordinator.textToSpeechSettings.shortcutsEnabled
        let enable = checkbox("Enable Text to Speech shortcuts", ttsEnabled, #selector(toggleTextToSpeechShortcuts(_:)), id: "shortcuts.ttsEnabled")
        let read = recorder(for: .readSelectedText, shortcut: bindings.readSelectedText)
        read.isEnabled = ttsEnabled
        let pause = recorder(for: .pauseOrResumeReadback, shortcut: bindings.pauseOrResumeReadback)
        pause.isEnabled = ttsEnabled
        let ttsForm = formGrid([
            ("Read Selected Text:", read),
            ("Pause or Resume Readback:", pause)
        ])
        let ttsGroup = groupStack()
        ttsGroup.addArrangedSubview(enable)
        ttsGroup.addArrangedSubview(ttsForm)
        ttsGroup.addArrangedSubview(wrappingLabel("Escape always stops readback. Reading selected text needs Accessibility permission.", secondary: true))
        add(section("Text to Speech", ttsGroup), to: pageStack)

        // Conflicts and reset
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        let conflicts = bindings.conflicts()
        if !conflicts.isEmpty {
            let names = conflicts.map { "\($0.0.title) and \($0.1.title)" }.joined(separator: "; ")
            let warning = wrappingLabel("Same shortcut used by \(names). Only the first action will respond.", secondary: false)
            warning.textColor = .systemOrange
            warning.identifier = NSUserInterfaceItemIdentifier("shortcuts.conflict")
            footer.addArrangedSubview(warning)
        }
        let reset = button("Restore Defaults", #selector(resetShortcuts), id: "shortcuts.reset")
        reset.isEnabled = bindings != .standard
        let footerRow = spread(footer, trailing: reset)
        add(footerRow, to: pageStack)
        return pageStack
    }

    private func recorder(for action: ShortcutAction, shortcut: KeyboardShortcut?) -> ShortcutRecorderView {
        let recorder = ShortcutRecorderView()
        recorder.shortcut = shortcut
        recorder.identifier = NSUserInterfaceItemIdentifier("shortcuts.\(action.rawValue)")
        recorder.toolTip = action.detail
        recorder.onRecordingStateChange = { [weak self] recording in
            self?.isRecordingShortcut = recording
            self?.coordinator.setShortcutRecordingActive(recording)
        }
        recorder.onChange = { [weak self] newShortcut in
            guard let self else { return }
            var bindings = self.coordinator.settings.bindings
            if action == .quickDictation {
                bindings.quickDictation = newShortcut.map { .keyboardShortcut($0) } ?? .functionKey
            } else {
                bindings[action] = newShortcut
            }
            self.coordinator.setShortcutBindings(bindings)
            self.render(.shortcuts, preserveScroll: true)
        }
        return recorder
    }

    // MARK: - Models & Startup page

    private func modelsPage() -> NSView {
        coordinator.refreshInstalledSpeechModels()
        coordinator.refreshTextToSpeechInstallStatus()
        let pageStack = pageContainer(
            "Models & Startup",
            "Each feature runs its own local model. Enable a feature, choose which model it uses, and decide whether it loads when the app starts. Models stay on this Mac."
        )
        add(section("Startup", startupCard()), to: pageStack)
        add(section("Speech to Text", speechToTextModelCard()), to: pageStack)
        add(section("Text to Speech", textToSpeechModelCard()), to: pageStack)
        return pageStack
    }

    private func startupCard() -> NSStackView {
        let group = groupStack()
        let state = coordinator.loginItemState
        let checkbox = checkbox("Open Local Dictation when you log in", state == .enabled, #selector(toggleOpenAtLogin(_:)), id: "models.openAtLogin")
        checkbox.isEnabled = state != .unsupported
        group.addArrangedSubview(checkbox)
        switch state {
        case .unsupported:
            group.addArrangedSubview(wrappingLabel(
                coordinator.isTextToSpeechPreview
                    ? "Not available in the development preview."
                    : "Available once the app is installed in Applications.",
                secondary: true
            ))
        case .requiresApproval:
            let row = spread(
                wrappingLabel("Turned off in System Settings › General › Login Items. Turn it on there to open the app at login.", secondary: true),
                trailing: button("Open Login Items…", #selector(openLoginItems), id: "models.loginItems")
            )
            addFullWidth(row, to: group)
        default:
            group.addArrangedSubview(wrappingLabel("The models you mark Load at startup are loaded as soon as the app opens.", secondary: true))
        }
        return group
    }

    private func idleUnloadPopup(selected: IdleUnloadMinutes?, action: Selector, id: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        for choice in IdleUnloadPolicy.choices {
            popup.addItem(withTitle: IdleUnloadPolicy.title(for: choice))
            popup.lastItem?.representedObject = choice.map(NSNumber.init(value:))
        }
        popup.selectItem(at: IdleUnloadPolicy.choices.firstIndex(where: { $0 == selected }) ?? 0)
        popup.target = self
        popup.action = action
        popup.identifier = NSUserInterfaceItemIdentifier(id)
        popup.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true
        popup.toolTip = "Frees the model's memory after a quiet period. It loads again automatically the next time you use the feature."
        return popup
    }

    private func speechToTextModelCard() -> NSStackView {
        let settings = coordinator.localFeatureSettings.dictation
        let group = groupStack()
        group.spacing = 12
        let presentation = FeatureStatusPresentation.speechToText(
            state: coordinator.state,
            engine: coordinator.dictationEngineStatus,
            enabled: settings.enabled
        )
        group.addArrangedSubview(wrappingLabel("Quick dictation, conversation transcripts, and file transcription.", secondary: true))
        group.addArrangedSubview(featureToggles(feature: .speechToText, enabled: settings.enabled, loadAtStartup: settings.loadAtStartup))

        let installed = coordinator.installedSpeechModels
        let picker = NSPopUpButton()
        if installed.isEmpty { picker.addItem(withTitle: "No models downloaded") }
        for model in installed {
            picker.addItem(withTitle: model.title)
            picker.lastItem?.representedObject = model.id
        }
        if let selected = installed.firstIndex(where: { $0.url.standardizedFileURL == coordinator.configuration.modelURL.standardizedFileURL }) {
            picker.selectItem(at: selected)
        } else if !installed.isEmpty {
            picker.addItem(withTitle: "Select a model…")
            picker.selectItem(at: picker.numberOfItems - 1)
        }
        picker.target = self
        picker.action = #selector(selectInstalledASR(_:))
        picker.isEnabled = !installed.isEmpty && coordinator.canEditSpeechConfiguration
        picker.identifier = NSUserInterfaceItemIdentifier("models.asr.model")
        picker.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true
        let addModel = button("Add Model…", #selector(showASRCatalog(_:)), id: "models.asr.add")
        addModel.isEnabled = coordinator.canEditSpeechConfiguration
        if case .downloading = coordinator.modelDownloadState { addModel.isEnabled = false }
        let modelRow = NSStackView(views: [picker, addModel])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8

        let hasSelectableModel = installed.contains(where: { $0.url.standardizedFileURL == coordinator.configuration.modelURL.standardizedFileURL })
        let ready = coordinator.dictationEngineStatus == .ready
        let load = button(ready ? "Unload" : "Load Now", #selector(loadDictation), id: "models.asr.load")
        load.isEnabled = settings.enabled && hasSelectableModel
            && coordinator.dictationEngineStatus != .loading && !coordinator.isDictationEngineUnloading
        let statusRow = modelStatusRow(presentation, action: load)
        let idle = idleUnloadPopup(selected: settings.idleUnloadMinutes, action: #selector(changeDictationIdleUnload(_:)), id: "models.asr.idleUnload")
        group.addArrangedSubview(formGrid([("Model:", modelRow), ("Status:", statusRow), ("Memory:", idle)]))

        if let detail = coordinator.dictationEngineStatusDetail, !detail.isEmpty {
            let errorDetail = wrappingLabel(detail, secondary: false)
            errorDetail.textColor = .systemRed
            errorDetail.identifier = NSUserInterfaceItemIdentifier("models.asr.errorDetail")
            group.addArrangedSubview(errorDetail)
        }
        switch coordinator.modelDownloadState {
        case .downloading(let specification, let received, let total):
            let progress = NSProgressIndicator()
            progress.isIndeterminate = total == 0
            progress.minValue = 0
            progress.maxValue = Double(max(total, 1))
            progress.doubleValue = Double(received)
            progress.controlSize = .small
            progress.style = .bar
            progress.identifier = NSUserInterfaceItemIdentifier("models.asr.progress")
            let percent = total > 0 ? "\(Int(Double(received) / Double(total) * 100))%" : "preparing…"
            group.addArrangedSubview(label("Downloading \(specification.title) · \(percent)"))
            group.addArrangedSubview(progress)
            progress.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            group.addArrangedSubview(button("Cancel Download", #selector(cancelASRDownload), id: "models.asr.cancel"))
        case .failed(_, let message):
            let error = wrappingLabel(message, secondary: false)
            error.textColor = .systemRed
            group.addArrangedSubview(error)
        case .completed(let specification, _):
            group.addArrangedSubview(wrappingLabel("Downloaded \(specification.title). It is available in the Model list.", secondary: true))
        case .idle:
            break
        }
        return group
    }

    private func textToSpeechModelCard() -> NSStackView {
        let settings = coordinator.localFeatureSettings.readAloud
        let group = groupStack()
        group.spacing = 12
        let presentation = FeatureStatusPresentation.textToSpeech(
            state: coordinator.textToSpeechState,
            engine: coordinator.readAloudEngineStatus,
            enabled: settings.enabled
        )
        group.addArrangedSubview(wrappingLabel("Reads selected text aloud and creates audio files locally.", secondary: true))
        group.addArrangedSubview(featureToggles(feature: .textToSpeech, enabled: settings.enabled, loadAtStartup: settings.loadAtStartup))

        let picker = NSPopUpButton()
        let families = coordinator.installedTextToSpeechFamilies
        if families.isEmpty {
            picker.addItem(withTitle: "No models downloaded")
        } else {
            for family in families {
                picker.addItem(withTitle: family.model == .bf16 ? "Qwen 1.7B (BF16)" : "Qwen 1.7B (8-bit)")
                picker.lastItem?.representedObject = family.id
            }
            if let selected = families.firstIndex(where: { $0.model == settings.model }) {
                picker.selectItem(at: selected)
            } else {
                picker.addItem(withTitle: "Select a model…")
                picker.selectItem(at: picker.numberOfItems - 1)
            }
        }
        picker.target = self
        picker.action = #selector(selectInstalledTTSFamily(_:))
        picker.identifier = NSUserInterfaceItemIdentifier("models.tts.model")
        picker.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true
        picker.isEnabled = !families.isEmpty && !coordinator.textToSpeechInstallState.isActive && !coordinator.isTextToSpeechOperationActive
        let addModel = button("Add Model…", #selector(showTTSCatalog(_:)), id: "models.tts.add")
        addModel.isEnabled = !coordinator.textToSpeechInstallState.isActive
        let modelRow = NSStackView(views: [picker, addModel])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8

        let hasSelectableModel = families.contains(where: { $0.model == settings.model && $0.isUsableForPresets })
        let ready = coordinator.readAloudEngineStatus == .ready
        let load = button(ready ? "Unload" : "Load Now", #selector(loadReadAloud), id: "models.tts.load")
        load.isEnabled = settings.enabled && hasSelectableModel && coordinator.readAloudEngineStatus != .loading
        let statusRow = modelStatusRow(presentation, action: load)
        let idle = idleUnloadPopup(selected: settings.idleUnloadMinutes, action: #selector(changeReadAloudIdleUnload(_:)), id: "models.tts.idleUnload")
        group.addArrangedSubview(formGrid([("Model:", modelRow), ("Status:", statusRow), ("Memory:", idle)]))
        group.addArrangedSubview(wrappingLabel("Ryan, Vivian, and the other preset voices are included with the model. Creating a custom voice needs the two optional downloads below.", secondary: true))
        group.addArrangedSubview(ttsInstallControls())
        return group
    }

    /// Status dot and label in a fixed-width column so the Load/Unload button
    /// lines up with the Add Model button above it.
    private func modelStatusRow(_ presentation: FeatureStatusPresentation, action: NSButton) -> NSStackView {
        let status = statusLine(presentation)
        status.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true
        let row = NSStackView(views: [status, action])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func featureToggles(feature: Page, enabled: Bool, loadAtStartup: Bool) -> NSStackView {
        let isSpeech = feature == .speechToText
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        let enabledButton = checkbox(
            "Enable \(feature.title)",
            enabled,
            isSpeech ? #selector(toggleDictation(_:)) : #selector(toggleReadAloud(_:)),
            id: isSpeech ? "models.asr.enabled" : "models.tts.enabled"
        )
        let startupButton = checkbox(
            "Load at startup",
            loadAtStartup,
            isSpeech ? #selector(toggleDictationStartup(_:)) : #selector(toggleReadAloudStartup(_:)),
            id: isSpeech ? "models.asr.startup" : "models.tts.startup"
        )
        startupButton.isEnabled = enabled
        row.addArrangedSubview(enabledButton)
        row.addArrangedSubview(startupButton)
        return row
    }

    private func ttsInstallControls() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let installed = coordinator.textToSpeechModelInstallStatus
        let selectedFamily = coordinator.installedTextToSpeechFamilies.first(where: { $0.model == coordinator.localFeatureSettings.readAloud.model })
        let hasSelectedPresetVoices = selectedFamily?.customVoiceInstalled == true
        if coordinator.installedTextToSpeechFamilies.contains(where: { $0.customVoiceInstalled && !$0.runtimeInstalled }) {
            let runtime = button("Set Up Text to Speech Runtime", #selector(installTTSRuntime), id: "models.tts.runtime")
            runtime.isEnabled = !coordinator.textToSpeechInstallState.isActive
            stack.addArrangedSubview(runtime)
        }
        let presetDetail = "Preset voices (Qwen CustomVoice) are ready-made speakers for readback and audio files. Choose a speaker and optionally add a delivery instruction. Ryan is the default."
        let presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.alignment = .centerY
        presetRow.spacing = 6
        presetRow.addArrangedSubview(infoButton("Preset voices", detail: presetDetail))
        if installed.customVoiceInstalled {
            let preset = label("Preset voices downloaded (Ryan and Aiden)")
            preset.identifier = NSUserInterfaceItemIdentifier("models.tts.customVoice")
            presetRow.addArrangedSubview(checkmark())
            presetRow.addArrangedSubview(preset)
        } else {
            let hint = label("Add a voice model to download the preset voices.")
            hint.textColor = .secondaryLabelColor
            presetRow.addArrangedSubview(hint)
        }
        stack.addArrangedSubview(presetRow)

        let custom = NSButton(title: "Custom voices (optional)", target: self, action: #selector(toggleCustomVoiceDownloads(_:)))
        custom.isBordered = false
        custom.image = NSImage(systemSymbolName: showingCustomVoiceDownloads ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        custom.imagePosition = .imageLeading
        custom.identifier = NSUserInterfaceItemIdentifier("models.tts.customDisclosure")
        stack.addArrangedSubview(custom)
        guard showingCustomVoiceDownloads else { return installStatus(stack) }

        let precision = selectedFamily.map { $0.model == .bf16 ? "BF16" : "8-bit" }
        let customHint = label(precision.map { "Custom voice tools for the selected \($0) model" } ?? "Select a downloaded voice model first.")
        customHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(customHint)
        for component in [TextToSpeechModelComponent.voiceDesign, .base] {
            let hasComponent: Bool
            switch component {
            case .customVoice: hasComponent = installed.customVoiceInstalled
            case .voiceDesign: hasComponent = installed.voiceDesignInstalled
            case .base: hasComponent = installed.baseInstalled
            }
            let size = coordinator.localFeatureSettings.readAloud.model == .bf16 ? "4.5 GB" : "3.1 GB"
            let displayTitle = component == .voiceDesign ? "Voice Design" : "Voice Replay"
            let detail = component == .voiceDesign
                ? "Voice Design (Qwen VoiceDesign) lets you describe a voice in words. It creates the reference used by a custom voice; it is not the long-form playback model."
                : "Voice Replay (Qwen Base) reads text using a saved voice reference. It is required after Voice Design for repeatable long readings."
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.addArrangedSubview(infoButton(displayTitle, detail: detail))
            if hasComponent {
                row.addArrangedSubview(checkmark())
                row.addArrangedSubview(label("\(displayTitle) installed"))
            } else {
                let download = button("Download \(displayTitle) (\(size))", #selector(downloadTTSComponent(_:)), id: "models.tts.\(component.rawValue)")
                download.tag = TextToSpeechModelComponent.allCases.firstIndex(of: component) ?? 0
                download.isEnabled = coordinator.localFeatureSettings.readAloud.enabled && hasSelectedPresetVoices && !coordinator.textToSpeechInstallState.isActive
                row.addArrangedSubview(download)
            }
            stack.addArrangedSubview(row)
        }
        return installStatus(stack)
    }

    private func installStatus(_ stack: NSStackView) -> NSStackView {
        switch coordinator.textToSpeechInstallState {
        case .idle:
            break
        case .settingUpRuntime:
            installProgress("Setting up the Text to Speech runtime…", into: stack)
        case .downloading(let component, _):
            installProgress("Downloading \(component.title)…", into: stack)
        case .completed(let detail):
            installProgress(detail, into: stack)
        case .failed(let detail):
            let error = wrappingLabel(detail, secondary: false)
            error.maximumNumberOfLines = 3
            error.textColor = .systemRed
            stack.addArrangedSubview(error)
        case .canceling:
            stack.addArrangedSubview(label("Canceling download…"))
        }
        if coordinator.textToSpeechInstallState.isActive {
            let progress = NSProgressIndicator()
            progress.isIndeterminate = true
            progress.style = .spinning
            progress.controlSize = .small
            progress.startAnimation(nil)
            let row = NSStackView(views: [progress, button("Cancel", #selector(cancelTTSInstall), id: "models.tts.cancel")])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func installProgress(_ title: String, into stack: NSStackView) {
        stack.addArrangedSubview(label(title))
        guard !coordinator.textToSpeechInstallDetail.isEmpty else { return }
        let detail = wrappingLabel(coordinator.textToSpeechInstallDetail, secondary: true)
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(detail)
    }

    private func infoButton(_ title: String, detail: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About \(title)")!, target: self, action: #selector(showModelInfo(_:)))
        button.isBordered = false
        button.toolTip = detail
        button.identifier = NSUserInterfaceItemIdentifier("info.\(title)")
        button.setAccessibilityLabel("About \(title)")
        return button
    }

    // MARK: - Shared building blocks

    private func pageContainer(_ title: String, _ detail: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Layout.sectionSpacing
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        header.addArrangedSubview(heading)
        let description = wrappingLabel(detail, secondary: true)
        header.addArrangedSubview(description)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        description.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        return stack
    }

    /// Adds a section to a page and stretches it to the page width.
    private func add(_ section: NSView, to pageStack: NSStackView) {
        pageStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
    }

    /// A titled group: a small heading above a rounded, inset panel.
    private func section(_ title: String, _ body: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(heading)
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = .controlBackgroundColor
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        let container = NSView()
        box.contentView = container
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.groupInset),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.groupInset),
            body.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.groupInset),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.groupInset)
        ])
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// Adds a row that spans the full panel width so trailing controls line up.
    private func addFullWidth(_ row: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func groupStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    /// Right-aligned labels in a fixed column, controls leading in the next.
    private func formGrid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { row -> [NSView] in
            let title = NSTextField(labelWithString: row.0)
            title.alignment = .right
            title.setContentHuggingPriority(.required, for: .horizontal)
            return [title, row.1]
        })
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Layout.formLabelWidth
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .none
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }
        return grid
    }

    /// Leading content with an optional trailing control pinned to the right.
    private func spread(_ leading: NSView, trailing: NSView?) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        row.addArrangedSubview(leading)
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let trailing {
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(trailing)
        }
        return row
    }

    private func statusLine(_ presentation: FeatureStatusPresentation) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        let dot = NSImageView(image: MenuBarController.statusDot(presentation) ?? NSImage())
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setAccessibilityLabel(presentation.label)
        row.addArrangedSubview(dot)
        let text = NSTextField(labelWithString: presentation.label)
        text.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        text.identifier = NSUserInterfaceItemIdentifier("status.\(presentation.label)")
        row.addArrangedSubview(text)
        if let detail = presentation.detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.toolTip = detail
            row.addArrangedSubview(detailLabel)
        }
        return row
    }

    enum PermissionRowState {
        case allowed
        case notAllowed
        /// The app cannot confirm the permission yet; `label` says why.
        case unverified(label: String)

        var label: String {
            switch self {
            case .allowed: return "Allowed"
            case .notAllowed: return "Not allowed"
            case .unverified(let label): return label
            }
        }
    }

    private func permissionRow(
        _ title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: Selector,
        id: String,
        showsActionWhenGranted: Bool = false
    ) -> NSStackView {
        permissionRow(title, detail: detail, state: granted ? .allowed : .notAllowed, actionTitle: actionTitle, action: action, id: id, showsAction: !granted || showsActionWhenGranted)
    }

    private func permissionRow(
        _ title: String,
        detail: String,
        state: PermissionRowState,
        actionTitle: String,
        action: Selector,
        id: String,
        showsAction: Bool
    ) -> NSStackView {
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6
        let isAllowed: Bool
        if case .allowed = state { isAllowed = true } else { isAllowed = false }
        let status = NSImageView(image: isAllowed ? checkmarkImage() : circleImage())
        status.setAccessibilityLabel(state.label)
        titleRow.addArrangedSubview(status)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleRow.addArrangedSubview(titleLabel)
        let stateLabel = NSTextField(labelWithString: state.label)
        stateLabel.textColor = isAllowed ? .systemGreen : .secondaryLabelColor
        stateLabel.identifier = NSUserInterfaceItemIdentifier("\(id).state")
        titleRow.addArrangedSubview(stateLabel)
        text.addArrangedSubview(titleRow)
        let detailLabel = wrappingLabel(detail, secondary: true)
        text.addArrangedSubview(detailLabel)
        detailLabel.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        let actionButton: NSButton? = showsAction ? button(actionTitle, action, id: id) : nil
        let row = spread(text, trailing: actionButton)
        row.alignment = .top
        row.identifier = NSUserInterfaceItemIdentifier("\(id).row")
        return row
    }

    private func checkmark() -> NSImageView {
        let view = NSImageView(image: checkmarkImage())
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func checkmarkImage() -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [.systemGreen]))
        let image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Allowed")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }

    private func circleImage() -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [.tertiaryLabelColor]))
        let image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Not allowed")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func wrappingLabel(_ text: String, secondary: Bool) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.maximumNumberOfLines = 0
        if secondary { field.textColor = .secondaryLabelColor }
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func button(_ title: String, _ selector: Selector, id: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        if let id { button.identifier = NSUserInterfaceItemIdentifier(id) }
        return button
    }

    private func linkButton(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.isBordered = false
        button.contentTintColor = .linkColor
        return button
    }

    private func checkbox(_ title: String, _ on: Bool, _ selector: Selector, id: String) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: selector)
        box.state = on ? .on : .off
        box.identifier = NSUserInterfaceItemIdentifier(id)
        return box
    }

    // MARK: - Actions

    @objc private func showModelInfo(_ sender: NSButton) {
        let popover = ModelCatalogPopover.makeInfoPopover(detail: sender.toolTip ?? "")
        catalogPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
    @objc private func toggleConversation() { coordinator.startOrStopConversationTranscript() }
    @objc private func transcribeFile() { coordinator.chooseMediaFileForTranscription() }
    @objc private func openTranscriptsFolder() { coordinator.openConversationTranscriptsFolder() }
    @objc private func requestMic() { coordinator.requestMicrophonePermission() }
    @objc private func openMicSettings() { coordinator.openMicrophoneSettings() }
    @objc private func requestAccessibility() { coordinator.requestAccessibilityPermission() }
    @objc private func openSystemAudioSettings() { coordinator.openSystemAudioSettings() }
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0 else { return }
        coordinator.setRecognitionLanguage(RecognitionLanguage.allCases[sender.indexOfSelectedItem])
    }
    @objc private func toggleLive(_ sender: NSButton) { coordinator.setShowLivePreview(sender.state == .on) }
    @objc private func togglePunctuation(_ sender: NSButton) { coordinator.setAutomaticPunctuation(sender.state == .on) }
    @objc private func toggleFillers(_ sender: NSButton) { coordinator.setRemoveFillers(sender.state == .on) }
    @objc private func toggleDictation(_ sender: NSButton) {
        coordinator.setDictationFeature(enabled: sender.state == .on, loadAtStartup: coordinator.localFeatureSettings.dictation.loadAtStartup)
        render(.models, preserveScroll: true)
    }
    @objc private func toggleDictationStartup(_ sender: NSButton) {
        coordinator.setDictationFeature(enabled: coordinator.localFeatureSettings.dictation.enabled, loadAtStartup: sender.state == .on)
        render(.models, preserveScroll: true)
    }
    @objc private func toggleReadAloud(_ sender: NSButton) {
        let current = coordinator.localFeatureSettings.readAloud
        coordinator.setReadAloudFeature(enabled: sender.state == .on, loadAtStartup: current.loadAtStartup, model: current.model)
        render(.models, preserveScroll: true)
    }
    @objc private func toggleReadAloudStartup(_ sender: NSButton) {
        let current = coordinator.localFeatureSettings.readAloud
        coordinator.setReadAloudFeature(enabled: current.enabled, loadAtStartup: sender.state == .on, model: current.model)
        render(.models, preserveScroll: true)
    }
    @objc private func selectInstalledTTSFamily(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let family = coordinator.installedTextToSpeechFamilies.first(where: { $0.id == id }) else { return }
        coordinator.selectInstalledTextToSpeechFamily(family)
        render(.models, preserveScroll: true)
    }
    @objc private func loadDictation() {
        coordinator.dictationEngineStatus == .ready ? coordinator.unloadDictationEngine() : coordinator.loadDictationEngine()
    }
    @objc private func loadReadAloud() {
        coordinator.readAloudEngineStatus == .ready ? coordinator.unloadReadAloudEngine() : coordinator.loadReadAloudEngine()
    }
    @objc private func cancelASRDownload() { coordinator.cancelModelDownload() }
    @objc private func selectInstalledASR(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let model = coordinator.installedSpeechModels.first(where: { $0.id == id }) else { return }
        coordinator.selectInstalledSpeechModel(model)
        render(.models, preserveScroll: true)
    }
    @objc private func showASRCatalog(_ sender: NSButton) {
        let installed = coordinator.installedSpeechModels
        let items = [
            ModelCatalogPopover.Item(
                title: "English dictation (Q8) · 700 MB",
                summary: "Fast local transcription for English.",
                detail: "Fast local transcription for English. Keeps punctuation and capitalization. Download this when English is all you need.",
                installed: installed.contains(where: { $0.variant == .english }),
                add: { [weak self] in self?.coordinator.downloadEnglishModel() }
            ),
            ModelCatalogPopover.Item(
                title: "Multilingual dictation (Q8) · 742 MB",
                summary: "Choose a language or use Auto Detect.",
                detail: "Local transcription for Spanish and other supported languages. Choose a language or use Auto Detect.",
                installed: installed.contains(where: { $0.variant == .multilingual }),
                add: { [weak self] in self?.coordinator.downloadMultilingualModel() }
            )
        ]
        ModelCatalogPopover.show(from: sender, items: items, importAction: { [weak self] in self?.coordinator.chooseModel() }, retaining: &catalogPopover)
    }
    @objc private func showTTSCatalog(_ sender: NSButton) {
        let families = coordinator.installedTextToSpeechFamilies
        let items = [
            ModelCatalogPopover.Item(
                title: "Qwen 1.7B • BF16 · 4.5 GB",
                summary: "Higher precision · more memory",
                detail: "Qwen CustomVoice BF16 uses the original 16-bit weights and includes the preset Ryan and Aiden voices. It needs a larger download and more memory than 8-bit.",
                installed: families.contains(where: { $0.model == .bf16 && $0.customVoiceInstalled }),
                add: { [weak self] in self?.coordinator.downloadTextToSpeechModel(.customVoice, for: .bf16) }
            ),
            ModelCatalogPopover.Item(
                title: "Qwen 1.7B • 8-bit · 3.1 GB",
                summary: "Smaller download · less memory",
                detail: "Qwen CustomVoice 8-bit is quantized for MLX, the Apple Silicon model runtime, and includes the preset Ryan and Aiden voices. It uses less download space and memory, with possible subtle voice-quality differences from BF16.",
                installed: families.contains(where: { $0.model == .eightBit && $0.customVoiceInstalled }),
                add: { [weak self] in self?.coordinator.downloadTextToSpeechModel(.customVoice, for: .eightBit) }
            )
        ]
        ModelCatalogPopover.show(from: sender, items: items, retaining: &catalogPopover)
    }
    @objc private func installTTSRuntime() { coordinator.installTextToSpeechRuntime() }
    @objc private func downloadTTSComponent(_ sender: NSButton) {
        guard TextToSpeechModelComponent.allCases.indices.contains(sender.tag) else { return }
        coordinator.downloadTextToSpeechModel(TextToSpeechModelComponent.allCases[sender.tag])
    }
    @objc private func cancelTTSInstall() { coordinator.cancelTextToSpeechInstall() }
    @objc private func toggleCustomVoiceDownloads(_ sender: NSButton) {
        showingCustomVoiceDownloads.toggle()
        render(.models, preserveScroll: true)
    }
    @objc private func changeDictationIdleUnload(_ sender: NSPopUpButton) {
        coordinator.setDictationIdleUnload(minutes: (sender.selectedItem?.representedObject as? NSNumber)?.intValue)
    }
    @objc private func changeReadAloudIdleUnload(_ sender: NSPopUpButton) {
        coordinator.setReadAloudIdleUnload(minutes: (sender.selectedItem?.representedObject as? NSNumber)?.intValue)
    }
    @objc private func toggleOpenAtLogin(_ sender: NSButton) {
        coordinator.setOpensAtLogin(sender.state == .on)
        render(.models, preserveScroll: true)
    }
    @objc private func openLoginItems() { coordinator.openLoginItemsSettings() }
    @objc private func changeQuickDictationTrigger(_ sender: NSPopUpButton) {
        var bindings = coordinator.settings.bindings
        if sender.indexOfSelectedItem == 0 {
            bindings.quickDictation = .functionKey
        } else if bindings.quickDictation.isFunctionKey {
            bindings.quickDictation = .keyboardShortcut(KeyboardShortcut(keyCode: 49, modifiers: [.control, .option]))
        }
        coordinator.setShortcutBindings(bindings)
        render(.shortcuts, preserveScroll: true)
    }
    @objc private func toggleTextToSpeechShortcuts(_ sender: NSButton) {
        coordinator.setTextToSpeechShortcutsEnabled(sender.state == .on)
        render(.shortcuts, preserveScroll: true)
    }
    @objc private func resetShortcuts() {
        coordinator.resetShortcutBindings()
        render(.shortcuts, preserveScroll: true)
    }

    // MARK: - Navigation entry points

    @objc func showModels() { select(.models) }
    @objc func showShortcuts() { select(.shortcuts) }
    func showDictation() { select(.speechToText) }
    func showDictationPermissions() { select(.speechToText) }
    func showReadAloudVoice() { select(.textToSpeech); tts?.showVoicePage() }
    func showReadAloudAudio() { select(.textToSpeech); tts?.showAudioPage() }
    func showReadAloudSetup() { showModels() }
    func showReadAloudSavedSpeech(at url: URL) { showReadAloudAudio(); tts?.showSavedSpeech(at: url) }
}

extension UnifiedLocalDictationWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { Page.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let page = Page(rawValue: row) else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: page.symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: page.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(title)
        cell.imageView = icon
        cell.textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let selected = Page(rawValue: sidebar.selectedRow), selected != page else { return }
        render(selected)
    }
}
