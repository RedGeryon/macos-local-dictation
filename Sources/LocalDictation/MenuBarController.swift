import AppKit

@MainActor
final class MenuBarController: NSObject {
    private weak var coordinator: AppCoordinator?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var conversationClockTask: Task<Void, Never>?
    private var savedIndicatorTask: Task<Void, Never>?
    private var savedIndicatorUntil: Date?
    private var savedIndicatorURL: URL?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "Local Dictation")
            button.image?.isTemplate = true
        }
        refresh()
    }

    func refresh() {
        guard let coordinator else { return }
        updateStatusButton(coordinator: coordinator)
        updateConversationClock(coordinator: coordinator)

        let menu = NSMenu()
        let title = NSMenuItem(title: "Local Dictation", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(
            string: "Local Dictation",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        menu.addItem(title)

        let status = NSMenuItem(title: "\(statusGlyph(for: coordinator.state))  \(coordinator.state.label)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        switch coordinator.state {
        case .installationRequired:
            menu.addItem(item("Install in Applications…", #selector(installInApplications)))
            menu.addItem(item("Why installation is required…", #selector(showSetup)))
        case .configurationRequired:
            menu.addItem(item("Finish Setup…", #selector(showSetup)))
            menu.addItem(item("Open Official Model Page", #selector(openModelPage)))
        case .permissionRequired:
            menu.addItem(item("Finish Setup…", #selector(showSetup)))
        case .serverUnavailable:
            menu.addItem(item("Restart Speech Engine", #selector(restartEngine)))
            menu.addItem(item("Check Setup…", #selector(showSetup)))
        case .error:
            menu.addItem(item("Dismiss and Try Again", #selector(dismissError)))
            menu.addItem(item("Open Settings…", #selector(showSetup)))
            menu.addItem(item("Restart Speech Engine", #selector(restartEngine)))
        case .ready:
            let hint = NSMenuItem(title: coordinator.settings.shortcut.title + " for Quick Dictation", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(item(
                "Start Conversation Transcript",
                #selector(toggleConversation),
                key: ConversationShortcut.menuKey,
                modifiers: [.control, .option]
            ))
            menu.addItem(conversationFilesMenu(coordinator: coordinator))
            menu.addItem(.separator())
            menu.addItem(item("Start Long Dictation (Microphone Only)", #selector(toggleHandsFree)))
            if coordinator.lastTranscript != nil {
                menu.addItem(item("Paste Last Quick Dictation", #selector(pasteLast)))
            }
        case .recording(.handsFree):
            menu.addItem(item("Stop Long Dictation and Insert", #selector(toggleHandsFree)))
            menu.addItem(item("Cancel Dictation", #selector(cancelDictation)))
        case .recording(.pushToTalk):
            let hint = NSMenuItem(title: "Release the shortcut to insert · Esc cancels", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(item("Cancel Dictation", #selector(cancelDictation)))
        case .recordingConversation:
            let hint = NSMenuItem(
                title: "Recording You + Mac Speaker · \(ConversationShortcut.title) again to stop and save",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(item(
                "Stop and Save Conversation Transcript",
                #selector(toggleConversation),
                key: ConversationShortcut.menuKey,
                modifiers: [.control, .option]
            ))
            let location = NSMenuItem(title: "Saving in Documents → Local Dictation Transcripts", action: nil, keyEquivalent: "")
            location.isEnabled = false
            menu.addItem(location)
            menu.addItem(item("Open Transcripts Folder", #selector(openConversationTranscriptsFolder)))
        case .savingConversation:
            let finishing = NSMenuItem(title: "Finishing and saving the current file…", action: nil, keyEquivalent: "")
            finishing.isEnabled = false
            menu.addItem(finishing)
            menu.addItem(item(
                coordinator.conversationRestartQueued
                    ? "Cancel Next Conversation"
                    : "Start Another When Saved",
                #selector(toggleConversation),
                key: ConversationShortcut.menuKey,
                modifiers: [.control, .option]
            ))
        default:
            let loading = NSMenuItem(title: "Please wait…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        }

        if coordinator.serverManager.isRunning {
            menu.addItem(.separator())
            menu.addItem(settingsMenu(coordinator: coordinator))
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSetup)))
        menu.addItem(helpMenu())
        menu.addItem(.separator())
        menu.addItem(item("Quit Local Dictation", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

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

    private func conversationFilesMenu(coordinator: AppCoordinator) -> NSMenuItem {
        let parent = NSMenuItem(title: "Conversation Transcripts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if coordinator.lastConversationTranscriptURL != nil {
            submenu.addItem(item("Open Last Transcript", #selector(openLastConversationTranscript)))
        }
        submenu.addItem(item("Open Transcripts Folder", #selector(openConversationTranscriptsFolder)))
        submenu.addItem(.separator())
        let location = NSMenuItem(title: "Documents/Local Dictation Transcripts", action: nil, keyEquivalent: "")
        location.isEnabled = false
        submenu.addItem(location)
        parent.submenu = submenu
        return parent
    }

    private func settingsMenu(coordinator: AppCoordinator) -> NSMenuItem {
        let parent = NSMenuItem(title: "Quick Dictation Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for shortcut in DictationShortcut.allCases {
            let entry = NSMenuItem(title: shortcut.title, action: #selector(selectShortcut(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = shortcut.rawValue
            entry.state = coordinator.settings.shortcut == shortcut ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())

        let preview = item("Show Live Transcript", #selector(togglePreview))
        preview.state = coordinator.settings.showLivePreview ? .on : .off
        submenu.addItem(preview)

        let fillers = item("Remove “um” and “uh”", #selector(toggleFillers))
        fillers.state = coordinator.settings.removeFillers ? .on : .off
        submenu.addItem(fillers)
        parent.submenu = submenu
        return parent
    }

    private func helpMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Help & Maintenance", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(item("Open Local Test Playground", #selector(openPlayground)))
        submenu.addItem(item("Official Model Page", #selector(openModelPage)))
        submenu.addItem(item("Model License", #selector(openModelLicense)))
        submenu.addItem(.separator())
        submenu.addItem(item("How to Remove…", #selector(showRemovalInstructions)))
        parent.submenu = submenu
        return parent
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
        button.toolTip = "Local Dictation — \(coordinator.state.label)"

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
            button.toolTip = "Recording conversation — \(ConversationShortcut.title) to stop and save"
        case .startingConversation:
            setStatusTitle(" Starting…", color: .secondaryLabelColor)
        case .savingConversation:
            setStatusTitle(
                coordinator.conversationRestartQueued ? " Saving → REC" : " Saving…",
                color: .secondaryLabelColor
            )
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
        }
        button.attributedTitle = attributed
    }

    private func statusGlyph(for state: AppState) -> String {
        switch state {
        case .ready: return "●"
        case .recording, .recordingConversation: return "●"
        case .installationRequired, .configurationRequired, .permissionRequired: return "◐"
        case .serverUnavailable, .error: return "!"
        default: return "◌"
        }
    }

    @objc private func showSetup() { coordinator?.showSetup() }
    @objc private func installInApplications() { coordinator?.installInApplications() }
    @objc private func openModelPage() { coordinator?.openModelPage() }
    @objc private func openModelLicense() { coordinator?.openModelLicense() }
    @objc private func openPlayground() { coordinator?.openPlayground() }
    @objc private func restartEngine() { coordinator?.restartSpeechEngine() }
    @objc private func toggleHandsFree() { coordinator?.startOrStopHandsFree() }
    @objc private func toggleConversation() { coordinator?.startOrStopConversationTranscript() }
    @objc private func pasteLast() { coordinator?.pasteLast() }
    @objc private func cancelDictation() { coordinator?.cancelDictationFromMenu() }
    @objc private func dismissError() { coordinator?.dismissError() }
    @objc private func openLastConversationTranscript() { coordinator?.openLastConversationTranscript() }
    @objc private func openConversationTranscriptsFolder() { coordinator?.openConversationTranscriptsFolder() }
    @objc private func showRemovalInstructions() { coordinator?.showRemovalInstructions() }
    @objc private func quit() { coordinator?.quit() }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let shortcut = DictationShortcut(rawValue: raw) else { return }
        coordinator?.setShortcut(shortcut)
    }

    @objc private func togglePreview() {
        guard let coordinator else { return }
        coordinator.setShowLivePreview(!coordinator.settings.showLivePreview)
    }

    @objc private func toggleFillers() {
        guard let coordinator else { return }
        coordinator.setRemoveFillers(!coordinator.settings.removeFillers)
    }
}
