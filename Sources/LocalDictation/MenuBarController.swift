import AppKit
import Combine

enum TextToSpeechPreviewPresentation {
    static func statusText(for state: TextToSpeechState) -> String { state.label }

    static func buttonTitle(for state: TextToSpeechState) -> String {
        switch state {
        case .ready, .idle: return " TTS"
        case .speaking(let paused): return paused ? " TTS paused" : " TTS reading…"
        case .generating: return " TTS generating…"
        case .starting: return " TTS preparing…"
        case .canceling: return " TTS canceling…"
        case .unavailable: return " TTS needs setup"
        case .error: return " TTS error"
        }
    }
}

/// The menu-bar item. The menu is rebuilt from coordinator state on every
/// `refresh()`; it is cheap, and it keeps every row derived from one source.
///
/// Layout (top to bottom):
///   Speech to Text   ← section header
///   ● status row     ← click opens the page that explains the status
///   …dictation actions for the current state
///   Text to Speech   ← section header
///   ● status row
///   …readback actions
///   Settings…, Models & Startup…, Help ▸
///   Quit
@MainActor
final class MenuBarController: NSObject {
    private weak var coordinator: AppCoordinator?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var conversationClockTask: Task<Void, Never>?
    private var savedIndicatorTask: Task<Void, Never>?
    private var savedIndicatorUntil: Date?
    private var savedIndicatorURL: URL?
    private var observation: AnyCancellable?
    private var currentSymbolName = "waveform.badge.mic"

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "Local Dictation")
            button.image?.isTemplate = true
        }
        // Every published change reaches the menu, so a status such as
        // "Loading…" cannot go stale when a code path forgets to refresh.
        observation = coordinator.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        refresh()
    }

    func refresh() {
        guard let coordinator else { return }
        updateStatusButton(coordinator: coordinator)
        updateConversationClock(coordinator: coordinator)

        let menu = NSMenu()
        menu.autoenablesItems = false
        addSpeechToTextSection(to: menu, coordinator: coordinator)
        menu.addItem(.separator())
        addTextToSpeechSection(to: menu, coordinator: coordinator)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSetup), key: ","))
        menu.addItem(item("Models & Startup…", #selector(showModelsAndStartup)))
        menu.addItem(helpMenu())
        menu.addItem(.separator())
        menu.addItem(item("Quit Local Dictation", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    // MARK: - Speech to Text

    private func addSpeechToTextSection(to menu: NSMenu, coordinator: AppCoordinator) {
        menu.addItem(sectionHeader("Speech to Text"))
        let presentation = FeatureStatusPresentation.speechToText(
            state: coordinator.state,
            engine: coordinator.dictationEngineStatus,
            enabled: coordinator.localFeatureSettings.dictation.enabled
        )
        let statusAction: Selector = switch coordinator.state {
        case .permissionRequired: #selector(showDictationPermissions)
        case .installationRequired: #selector(showSetup)
        default: #selector(showModelsAndStartup)
        }
        menu.addItem(statusRow(presentation, action: statusAction))
        if case .downloading(let specification, let receivedBytes, let totalBytes) = coordinator.modelDownloadState {
            let percent = totalBytes > 0 ? min(100, Int((Double(receivedBytes) / Double(totalBytes)) * 100)) : 0
            menu.addItem(disabledItem("Downloading \(specification.title) · \(percent)%"))
        }

        let bindings = coordinator.settings.bindings
        switch coordinator.state {
        case .installationRequired:
            menu.addItem(item("Install in Applications…", #selector(installInApplications)))
        case .configurationRequired:
            menu.addItem(item("Choose a Speech Model…", #selector(showModelsAndStartup)))
        case .permissionRequired:
            menu.addItem(item("Review Permissions…", #selector(showDictationPermissions)))
            if coordinator.canTranscribeMediaFile {
                menu.addItem(item("Transcribe Audio or Video File…", #selector(transcribeMediaFile)))
            }
        case .serverUnavailable:
            menu.addItem(item("Restart Speech Engine", #selector(restartEngine)))
        case .error:
            menu.addItem(item("Dismiss and Try Again", #selector(dismissError)))
            menu.addItem(item("Restart Speech Engine", #selector(restartEngine)))
        case .ready:
            guard coordinator.localFeatureSettings.dictation.enabled else {
                menu.addItem(item("Enable Speech to Text…", #selector(showModelsAndStartup)))
                break
            }
            let engineReady = coordinator.dictationEngineStatus == .ready
            let available = engineReady && !coordinator.isTextToSpeechOperationActive
            if engineReady {
                menu.addItem(disabledItem("\(bindings.quickDictation.title) to dictate"))
            } else if coordinator.dictationEngineStatus == .notLoaded {
                menu.addItem(item("Load Speech Model", #selector(loadDictationEngine)))
            }
            let longDictation = item("Start Long Dictation", #selector(toggleHandsFree), shortcut: bindings.toggleLongDictation)
            longDictation.isEnabled = available
            menu.addItem(longDictation)
            let conversation = item("Start Conversation Transcript", #selector(toggleConversation), shortcut: bindings.toggleConversation)
            conversation.isEnabled = available
            menu.addItem(conversation)
            let file = item("Transcribe Audio or Video File…", #selector(transcribeMediaFile))
            file.isEnabled = available && coordinator.canTranscribeMediaFile
            menu.addItem(file)
            if !coordinator.dictationHistory.isEmpty {
                menu.addItem(item("Paste Last Quick Dictation", #selector(pasteLast)))
                menu.addItem(recentDictationsMenu(coordinator: coordinator))
            }
            menu.addItem(transcriptsMenu(coordinator: coordinator))
        case .inspectingMedia:
            menu.addItem(disabledItem(coordinator.mediaFileStatusText.isEmpty ? "Reading media file…" : coordinator.mediaFileStatusText))
            menu.addItem(item("Cancel File Transcription", #selector(cancelMediaFileTranscription)))
        case .transcribingFile:
            let percent = min(99, max(0, Int(coordinator.mediaFileProgress * 100)))
            menu.addItem(disabledItem("\(coordinator.mediaFileStatusText) · \(percent)%"))
            if let name = coordinator.mediaFileName { menu.addItem(disabledItem(name)) }
            menu.addItem(item("Cancel File Transcription", #selector(cancelMediaFileTranscription)))
        case .recording(.handsFree):
            menu.addItem(item("Stop Long Dictation and Insert", #selector(toggleHandsFree), shortcut: bindings.toggleLongDictation))
            menu.addItem(item("Cancel Dictation", #selector(cancelDictation)))
        case .recording(.pushToTalk):
            menu.addItem(disabledItem("Release the shortcut to insert · Esc cancels"))
            menu.addItem(item("Cancel Dictation", #selector(cancelDictation)))
        case .recordingConversation:
            menu.addItem(item("Stop and Save Conversation Transcript", #selector(toggleConversation), shortcut: bindings.toggleConversation))
            menu.addItem(disabledItem("Recording you and the Mac speaker"))
            menu.addItem(item("Open Transcripts Folder", #selector(openConversationTranscriptsFolder)))
        case .savingConversation:
            menu.addItem(disabledItem("Finishing and saving the transcript…"))
            menu.addItem(item(
                coordinator.conversationRestartQueued ? "Cancel Next Conversation" : "Start Another When Saved",
                #selector(toggleConversation),
                shortcut: bindings.toggleConversation
            ))
        default:
            menu.addItem(disabledItem("Please wait…"))
        }
    }

    // MARK: - Text to Speech

    private func addTextToSpeechSection(to menu: NSMenu, coordinator: AppCoordinator) {
        menu.addItem(sectionHeader("Text to Speech"))
        let presentation = FeatureStatusPresentation.textToSpeech(
            state: coordinator.textToSpeechState,
            engine: coordinator.readAloudEngineStatus,
            enabled: coordinator.localFeatureSettings.readAloud.enabled
        )
        menu.addItem(statusRow(presentation, action: #selector(showModelsAndStartup)))

        let bindings = coordinator.settings.bindings
        guard coordinator.localFeatureSettings.readAloud.enabled else {
            menu.addItem(item("Enable Text to Speech…", #selector(showModelsAndStartup)))
            return
        }
        if coordinator.isTextToSpeechOperationActive {
            if case .speaking(let paused) = coordinator.textToSpeechState {
                menu.addItem(item(paused ? "Resume Readback" : "Pause Readback", #selector(pauseOrResumeTextToSpeech), shortcut: bindings.pauseOrResumeReadback))
            }
            menu.addItem(item("Stop Readback", #selector(cancelTextToSpeech), key: "\u{1b}", modifiers: []))
        } else {
            if coordinator.readAloudEngineStatus == .notLoaded, coordinator.textToSpeechIssueMessage == nil {
                menu.addItem(item("Load Voice Model", #selector(loadReadAloudEngine)))
            }
            let readSelected = item("Read Selected Text", #selector(readSelectedText), shortcut: bindings.readSelectedText)
            readSelected.isEnabled = coordinator.canUseTextToSpeech && coordinator.accessibilityGrantedForSelectedText
            menu.addItem(readSelected)
            if !coordinator.accessibilityGrantedForSelectedText {
                menu.addItem(item("Allow Accessibility for Read Selected Text…", #selector(enableTextToSpeechReadShortcuts)))
            }
            let clipboard = item("Read Clipboard", #selector(readClipboard))
            clipboard.isEnabled = coordinator.canUseTextToSpeech
            menu.addItem(clipboard)
            if coordinator.textToSpeechIssueMessage != nil {
                menu.addItem(item(coordinator.textToSpeechRecoveryActionTitle, #selector(showTextToSpeechSetup)))
            }
        }
        menu.addItem(voiceMenu(coordinator: coordinator))
        menu.addItem(item("Create Audio File…", #selector(showTextToSpeechAudioCreator)))
    }

    // MARK: - Test seams

    /// Internal seam for structural menu tests; it does not mutate preferences.
    func menuTitlesForTesting() -> [String] {
        refresh()
        return statusItem.menu?.items.map(\.title) ?? []
    }

    func menuForTesting() -> NSMenu? { refresh(); return statusItem.menu }

    func showConversationSaved(at fileURL: URL) {
        savedIndicatorTask?.cancel()
        savedIndicatorURL = fileURL
        savedIndicatorUntil = Date().addingTimeInterval(2.5)
        if let coordinator { updateStatusButton(coordinator: coordinator) }
        savedIndicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2_500))
            guard !Task.isCancelled, let self, let coordinator = self.coordinator else { return }
            self.savedIndicatorUntil = nil
            self.savedIndicatorURL = nil
            self.updateStatusButton(coordinator: coordinator)
        }
    }

    // MARK: - Submenus

    private func transcriptsMenu(coordinator: AppCoordinator) -> NSMenuItem {
        let parent = NSMenuItem(title: "Transcripts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if coordinator.lastConversationTranscriptURL != nil {
            submenu.addItem(item("Open Last Conversation Transcript", #selector(openLastConversationTranscript)))
        }
        if coordinator.lastFileTranscriptURL != nil {
            submenu.addItem(item("Open Last File Transcript", #selector(openLastFileTranscript)))
        }
        if submenu.numberOfItems > 0 { submenu.addItem(.separator()) }
        submenu.addItem(item("Open Conversation Transcripts Folder", #selector(openConversationTranscriptsFolder)))
        submenu.addItem(item("Open File Transcripts Folder", #selector(openFileTranscriptsFolder)))
        submenu.addItem(.separator())
        submenu.addItem(disabledItem("Documents › Local Dictation Transcripts"))
        parent.submenu = submenu
        return parent
    }

    /// The last few dictations of this session; choosing one inserts it again.
    private func recentDictationsMenu(coordinator: AppCoordinator) -> NSMenuItem {
        let parent = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for entry in coordinator.dictationHistory.entries {
            let row = NSMenuItem(title: entry.menuTitle, action: #selector(insertRecentDictation(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = entry.id
            row.toolTip = entry.text
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        submenu.addItem(disabledItem("Kept for this session only"))
        parent.submenu = submenu
        parent.identifier = NSUserInterfaceItemIdentifier("menu.recentDictations")
        return parent
    }

    private func helpMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(item("Keyboard Shortcuts…", #selector(showShortcuts)))
        submenu.addItem(item("Open Local Test Playground", #selector(openPlayground)))
        submenu.addItem(.separator())
        submenu.addItem(item("Selected Speech Model Page", #selector(openModelPage)))
        submenu.addItem(item("Selected Speech Model License", #selector(openModelLicense)))
        submenu.addItem(.separator())
        submenu.addItem(item("How to Remove…", #selector(showRemovalInstructions)))
        parent.submenu = submenu
        return parent
    }

    private func voiceMenu(coordinator: AppCoordinator) -> NSMenuItem {
        let active = coordinator.textToSpeechSettings.activeVoiceConfiguration.voiceID
        let menu = NSMenu()
        menu.autoenablesItems = false
        let backendVoices = coordinator.textToSpeechVoices.filter {
            $0.id != "voice-design" && $0.id != "voice-design-consistent"
        }
        let primary = TextToSpeechVoice.primaryVoiceIDs.map { id in
            backendVoices.first(where: { $0.id == id }) ?? TextToSpeechVoice.placeholder(id: id)
        }
        let secondary = backendVoices
            .filter { !TextToSpeechVoice.primaryVoiceIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for voice in primary { menu.addItem(voiceItem(voice.name, id: voice.id, active: active)) }
        if coordinator.hasSavedTextToSpeechVoice("voice-design-consistent") {
            menu.addItem(voiceItem("Custom Voice", id: "voice-design-consistent", active: active))
        }
        if !secondary.isEmpty { menu.addItem(.separator()) }
        for voice in secondary { menu.addItem(voiceItem(voice.name, id: voice.id, active: active)) }
        menu.addItem(.separator())
        menu.addItem(item("Voice Settings…", #selector(showTextToSpeechVoiceSettings)))
        let title = NSMenuItem(title: "Voice: \(voiceTitle(active, coordinator: coordinator))", action: nil, keyEquivalent: "")
        title.submenu = menu
        return title
    }

    private func voiceItem(_ name: String, id: String, active: String) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: #selector(useSavedVoice(_:)), keyEquivalent: "")
        item.representedObject = id
        item.state = id == active ? .on : .off
        item.target = self
        return item
    }

    private func voiceTitle(_ id: String, coordinator: AppCoordinator) -> String {
        switch id {
        case "voice-design-consistent": return "Custom Voice"
        default: return coordinator.textToSpeechVoices.first(where: { $0.id == id })?.name ?? TextToSpeechVoice.placeholder(id: id).name
        }
    }

    // MARK: - Item builders

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        return header
    }

    /// A status row: colored dot, short label, and an action that opens the
    /// page explaining the status. The tooltip carries any longer detail.
    private func statusRow(_ presentation: FeatureStatusPresentation, action: Selector) -> NSMenuItem {
        let row = NSMenuItem(title: presentation.label, action: action, keyEquivalent: "")
        row.target = self
        row.image = Self.statusDot(presentation)
        row.toolTip = presentation.detail
        row.identifier = NSUserInterfaceItemIdentifier("menu.status.\(presentation.label)")
        return row
    }

    /// The menu-bar glyph says what the app is doing right now: a microphone
    /// while listening, a speaker while reading aloud, the waveform otherwise.
    nonisolated static func statusSymbolName(state: AppState, textToSpeech: TextToSpeechState) -> String {
        switch state {
        case .recording, .recordingConversation, .startingConversation: return "mic.fill"
        case .transcribingFile, .inspectingMedia: return "doc.text.magnifyingglass"
        default: break
        }
        switch textToSpeech {
        case .speaking, .generating, .starting: return "speaker.wave.2.fill"
        default: return "waveform.badge.mic"
        }
    }

    static func statusDot(_ presentation: FeatureStatusPresentation) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(.init(paletteColors: [presentation.color]))
        let image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: presentation.label)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        result.isEnabled = false
        return result
    }

    private func item(_ title: String, _ action: Selector, shortcut: KeyboardShortcut?) -> NSMenuItem {
        guard let shortcut else { return item(title, action) }
        return item(title, action, key: shortcut.menuKeyEquivalent, modifiers: shortcut.menuKeyEquivalentModifierMask)
    }

    private func item(
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        result.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return result
    }

    // MARK: - Status button

    private func updateConversationClock(coordinator: AppCoordinator) {
        if coordinator.state == .recordingConversation {
            guard conversationClockTask == nil else { return }
            conversationClockTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, let coordinator = self.coordinator,
                          coordinator.state == .recordingConversation else { return }
                    self.updateStatusButton(coordinator: coordinator)
                }
            }
        } else {
            conversationClockTask?.cancel()
            conversationClockTask = nil
        }
    }

    private func updateStatusButton(coordinator: AppCoordinator) {
        guard let button = statusItem.button else { return }
        let speech = FeatureStatusPresentation.speechToText(
            state: coordinator.state,
            engine: coordinator.dictationEngineStatus,
            enabled: coordinator.localFeatureSettings.dictation.enabled
        )
        let readback = FeatureStatusPresentation.textToSpeech(
            state: coordinator.textToSpeechState,
            engine: coordinator.readAloudEngineStatus,
            enabled: coordinator.localFeatureSettings.readAloud.enabled
        )
        button.toolTip = "Local Dictation\nSpeech to Text: \(speech.label)\nText to Speech: \(readback.label)"
        button.contentTintColor = FeatureStatusPresentation.menuBarTint(speechToText: speech, textToSpeech: readback)
        let symbol = Self.statusSymbolName(state: coordinator.state, textToSpeech: coordinator.textToSpeechState)
        if symbol != currentSymbolName {
            currentSymbolName = symbol
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Local Dictation")
            button.image?.isTemplate = true
        }

        if coordinator.state == .ready,
           let until = savedIndicatorUntil,
           Date() < until {
            setStatusTitle(" ✓ Saved", color: .systemGreen)
            button.toolTip = savedIndicatorURL?.path ?? "Conversation transcript saved"
            return
        }

        switch coordinator.state {
        case .recordingConversation:
            let elapsed = Date().timeIntervalSince(coordinator.conversationStartedAt ?? Date())
            let total = max(0, Int(elapsed))
            let time = String(format: "%02d:%02d", total / 60, total % 60)
            setStatusTitle(" ● \(time)", color: .systemRed)
            let stop = coordinator.settings.bindings.toggleConversation?.displayString ?? "the conversation shortcut"
            button.toolTip = "Recording conversation — \(stop) to stop and save"
        case .startingConversation:
            setStatusTitle(" Starting…", color: .secondaryLabelColor)
        case .savingConversation:
            setStatusTitle(coordinator.conversationRestartQueued ? " Saving → REC" : " Saving…", color: .secondaryLabelColor)
        case .transcribingFile:
            let percent = min(99, max(0, Int(coordinator.mediaFileProgress * 100)))
            setStatusTitle(" \(percent)%", color: .systemBlue)
            button.toolTip = "Transcribing \(coordinator.mediaFileName ?? "media file") locally"
        default:
            statusItem.length = NSStatusItem.squareLength
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    private func setStatusTitle(_ title: String, color: NSColor) {
        guard let button = statusItem.button else { return }
        statusItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        )
        if let marker = title.range(of: "●") ?? title.range(of: "✓") {
            attributed.addAttribute(.foregroundColor, value: color, range: NSRange(marker, in: title))
        } else {
            attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: attributed.length))
        }
        button.attributedTitle = attributed
    }

    // MARK: - Actions

    @objc private func showSetup() { coordinator?.showSetup() }
    @objc private func showModelsAndStartup() { coordinator?.showModelsAndStartup() }
    @objc private func showDictationPermissions() { coordinator?.showDictationPermissions() }
    @objc private func showShortcuts() { coordinator?.showShortcutSettings() }
    @objc private func installInApplications() { coordinator?.installInApplications() }
    @objc private func openModelPage() { coordinator?.openModelPage() }
    @objc private func openModelLicense() { coordinator?.openModelLicense() }
    @objc private func openPlayground() { coordinator?.openPlayground() }
    @objc private func restartEngine() { coordinator?.restartSpeechEngine() }
    @objc private func loadDictationEngine() { coordinator?.loadDictationEngine() }
    @objc private func loadReadAloudEngine() { coordinator?.loadReadAloudEngine() }
    @objc private func toggleHandsFree() { coordinator?.startOrStopHandsFree() }
    @objc private func toggleConversation() { coordinator?.startOrStopConversationTranscript() }
    @objc private func transcribeMediaFile() { coordinator?.chooseMediaFileForTranscription() }
    @objc private func cancelMediaFileTranscription() { coordinator?.cancelMediaFileTranscription() }
    @objc private func openLastFileTranscript() { coordinator?.openLastFileTranscript() }
    @objc private func openFileTranscriptsFolder() { coordinator?.openFileTranscriptsFolder() }
    @objc private func pasteLast() { coordinator?.pasteLast() }
    @objc private func insertRecentDictation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator?.insertRecentDictation(id: id)
    }
    @objc private func readSelectedText() { coordinator?.readSelectedText() }
    @objc private func enableTextToSpeechReadShortcuts() { coordinator?.enableTextToSpeechReadShortcuts() }
    @objc private func readClipboard() { coordinator?.readClipboard() }
    @objc private func showTextToSpeechVoiceSettings() { coordinator?.showTextToSpeechVoiceSettings() }
    @objc private func showTextToSpeechAudioCreator() { coordinator?.showTextToSpeechAudioCreator() }
    @objc private func showTextToSpeechSetup() { coordinator?.showTextToSpeechSetup() }
    @objc private func useSavedVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        coordinator?.useSavedTextToSpeechVoice(id)
    }
    @objc private func pauseOrResumeTextToSpeech() { coordinator?.pauseOrResumeTextToSpeech() }
    @objc private func cancelTextToSpeech() { coordinator?.cancelTextToSpeech() }
    @objc private func cancelDictation() { coordinator?.cancelDictationFromMenu() }
    @objc private func dismissError() { coordinator?.dismissError() }
    @objc private func openLastConversationTranscript() { coordinator?.openLastConversationTranscript() }
    @objc private func openConversationTranscriptsFolder() { coordinator?.openConversationTranscriptsFolder() }
    @objc private func showRemovalInstructions() { coordinator?.showRemovalInstructions() }
    @objc private func quit() { coordinator?.quit() }
}
