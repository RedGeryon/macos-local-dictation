import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var state: AppState = .starting
    @Published private(set) var configuration = AppConfiguration()
    @Published private(set) var settings = DictationSettings()
    @Published private(set) var permissionStatus = DictationPermissionStatus(
        microphone: false,
        accessibility: false
    )
    @Published private(set) var permissionRequestInProgress = false
    @Published private(set) var systemAudioPermissionGranted = false
    @Published private(set) var speechEngineReady = false
    @Published private(set) var installationError: String?
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastConversationTranscriptURL: URL?
    @Published private(set) var conversationStartedAt: Date?
    @Published private(set) var conversationRestartQueued = false
    @Published private(set) var globalShortcutOperational = false
    @Published private(set) var modelDownloadState: ModelDownloadState = .idle
    @Published private(set) var mediaFileName: String?
    @Published private(set) var mediaFileProgress: Double = 0
    @Published private(set) var mediaFileStatusText = ""
    @Published private(set) var mediaFileEstimatedSeconds: TimeInterval = 0
    @Published private(set) var lastFileTranscriptURL: URL?

    let serverManager: SpeechServerManager
    let permissionManager = PermissionManager()

    private let realtimeClient = RealtimeTranscriptionClient()
    private let modelDownloader = ModelDownloader()
    private let mediaFileTranscriber = MediaFileTranscriptionService()
    private let audioCapture = AudioCaptureService()
    private let hotkeyController = GlobalHotkeyController()
    private let insertionService = TextInsertionService()
    private let overlayController = DictationOverlayController()
    private let logger = Logger(subsystem: "org.localdictation.app", category: "App")
    private var menuBarController: MenuBarController?
    private var setupWindowController: SetupWindowController?
    private var insertionTarget: InsertionTarget?
    private var lastRawTranscript: String?
    private var pendingModeAfterCancel: DictationMode?
    private var handsFreeLimitTask: Task<Void, Never>?
    private var targetCaptureTask: Task<Void, Never>?
    private var transientMessageTask: Task<Void, Never>?
    private var finalizationDelayTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?
    private var permissionMonitorTask: Task<Void, Never>?
    private var permissionRequestTask: Task<Void, Never>?
    private var permissionRequestID: UUID?
    private var modelDownloadTask: Task<Void, Never>?
    private var speechEngineTask: Task<Void, Never>?
    private var speechEngineOperationID: UUID?
    private var wakeRecoveryTask: Task<Void, Never>?
    private var terminationDeadlineTask: Task<Void, Never>?
    private var mediaFileTranscriptionTask: Task<Void, Never>?
    private var mediaFileProgressTask: Task<Void, Never>?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var pendingDownloadedModel: (SpeechModelDownloadSpecification, URL)?
    private var lastModelDownloadMenuPercent = -1
    private var lastMediaFileMenuPercent = -1
    private var realtimeConnected = false
    private var isQuitting = false
    private var isPowerTransitioning = false
    private var pushToTalkHeld = false
    private var systemAudioOperational = false
    private var conversationSession: ConversationTranscriptionSession?
    private let permissionRepairPendingKey = "permissionRepairPending"
    private let conversationConsentAcknowledgedKey = "conversationConsentAcknowledged"
    private static let releaseTailCaptureMilliseconds = 180

    var isInstalledInApplications: Bool {
        ApplicationInstallation.isInApplications(Bundle.main.bundleURL)
    }

    var terminationInProgress: Bool { isQuitting }

    var canTranscribeMediaFile: Bool {
        guard serverManager.isRunning, serverManager.fileTranscriptionURL != nil else { return false }
        return state == .ready || state == .permissionRequired
    }

    var canEditSpeechConfiguration: Bool {
        switch state {
        case .installationRequired, .configurationRequired, .permissionRequired,
             .serverUnavailable, .ready, .error:
            return true
        default:
            return false
        }
    }

    init(serverManager: SpeechServerManager = SpeechServerManager()) {
        self.serverManager = serverManager
        self.serverManager.onStateChange = { [weak self] state in
            guard let self, !self.isQuitting else { return }
            self.transition(to: state)
        }
        realtimeClient.onPartial = { [weak self] text in self?.handlePartial(text) }
        realtimeClient.onFinal = { [weak self] text in self?.handleFinal(text) }
        realtimeClient.onError = { [weak self] error in self?.handleRealtimeError(error) }
        realtimeClient.onConnectionChange = { [weak self] connected in
            self?.handleRealtimeConnection(connected)
        }
        realtimeClient.onCleared = { [weak self] in self?.handleRealtimeCleared() }
        hotkeyController.onEvent = { [weak self] event in self?.handleHotkey(event) }
    }

    func start() {
        menuBarController = MenuBarController(coordinator: self)
        startPermissionMonitoring()
        startPowerMonitoring()
        transition(to: .starting)

        guard isInstalledInApplications else {
            transition(to: .installationRequired)
            showSetup()
            return
        }

        let shouldResumePermissionRepair = UserDefaults.standard.bool(forKey: permissionRepairPendingKey)
        if shouldResumePermissionRepair {
            UserDefaults.standard.removeObject(forKey: permissionRepairPendingKey)
            showSetup()
        }

        if let issue = configuration.validate() {
            transition(to: .configurationRequired(issue))
            showSetup()
            return
        }

        scheduleSpeechEngineStart(restart: false)
    }

    func restartSpeechEngine() {
        cancelDictation()
        realtimeClient.disconnect()
        realtimeConnected = false
        speechEngineReady = false
        scheduleSpeechEngineStart(restart: true)
    }

    func requestMicrophonePermission() {
        guard isInstalledInApplications else { return showSetup() }
        beginPermissionRequest(for: .microphone)
    }

    func requestAccessibilityPermission() {
        guard isInstalledInApplications else { return showSetup() }
        beginPermissionRequest(for: .accessibility)
    }

    func installInApplications() {
        guard !isInstalledInApplications else { return }
        let source = Bundle.main.bundleURL
        let destination = ApplicationInstallation.destinationURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.messageText = "Replace the existing Local Dictation app?"
            alert.informativeText = "The existing copy in Applications will be moved to the Trash and replaced with this version. Your downloaded model and settings are kept."
            alert.addButton(withTitle: "Replace and Relaunch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            installationError = nil
            if fileManager.fileExists(atPath: destination.path) {
                var trashedURL: NSURL?
                try fileManager.trashItem(at: destination, resultingItemURL: &trashedURL)
            }
            try fileManager.copyItem(at: source, to: destination)
            try scheduleRelaunch(at: destination)
            isQuitting = true
            NSApp.terminate(nil)
        } catch {
            installationError = error.localizedDescription
            showSetup()
        }
    }

    func repairPermissionRegistration() {
        guard isInstalledInApplications else {
            transition(to: .installationRequired)
            showSetup()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Repair Local Dictation permissions?"
        alert.informativeText = "This clears only Local Dictation’s stale privacy entries and relaunches the installed app. Setup then lets you approve Microphone, Accessibility, and optional System Audio one at a time. Other apps are not affected."
        alert.addButton(withTitle: "Repair and Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            for service in ["Microphone", "Accessibility", "ScreenCapture"] {
                try resetPrivacyDecision(service: service)
            }
            UserDefaults.standard.set(true, forKey: permissionRepairPendingKey)
            try scheduleRelaunch(at: Bundle.main.bundleURL)
            quit()
        } catch {
            installationError = "Permission repair failed: \(error.localizedDescription)"
            showSetup()
        }
    }

    func refreshPermissions() {
        updatePermissionStatus()
        activateHotkeysIfPossible()
    }

    func setShortcut(_ shortcut: DictationShortcut) {
        settings.shortcut = shortcut
        settings.persist()
        hotkeyController.shortcut = shortcut
        menuBarController?.refresh()
    }

    func setRemoveFillers(_ enabled: Bool) {
        settings.removeFillers = enabled
        settings.persist()
        menuBarController?.refresh()
    }

    func setShowLivePreview(_ enabled: Bool) {
        settings.showLivePreview = enabled
        settings.persist()
        menuBarController?.refresh()
    }

    func startOrStopHandsFree() {
        switch state {
        case .recording(.handsFree):
            finishDictation()
        case .recording(.pushToTalk):
            cancelDictation(thenStart: .handsFree)
        case .ready:
            scheduleDictationStart(mode: .handsFree)
        default:
            break
        }
    }

    func startOrStopConversationTranscript() {
        switch state {
        case .recordingConversation:
            stopConversationTranscript()
        case .savingConversation:
            conversationRestartQueued.toggle()
            menuBarController?.refresh()
        case .ready:
            startConversationTranscript()
        default:
            break
        }
    }

    func requestSystemAudioPermission() {
        guard isInstalledInApplications else { return showSetup() }
        permissionManager.openSystemAudioSettings()
    }

    func openLastConversationTranscript() {
        guard let lastConversationTranscriptURL else { return }
        NSWorkspace.shared.open(lastConversationTranscriptURL)
    }

    func openConversationTranscriptsFolder() {
        do {
            let directory = try ConversationTranscriptWriter.transcriptsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            showRecoverableMessage("The transcript folder could not be opened: \(error.localizedDescription)")
        }
    }

    func chooseMediaFileForTranscription() {
        guard canTranscribeMediaFile,
              mediaFileTranscriptionTask == nil,
              let endpoint = serverManager.fileTranscriptionURL else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Audio or Video to Transcribe"
        panel.prompt = "Choose File"
        panel.message = MediaFileTranscriptionService.supportedFormatsDescription
        panel.allowedContentTypes = MediaFileTranscriptionService.selectableContentTypes
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        mediaFileName = fileURL.lastPathComponent
        mediaFileStatusText = "Reading duration and audio track…"
        mediaFileProgress = 0
        transition(to: .inspectingMedia)
        mediaFileTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let information = try await self.mediaFileTranscriber.inspect(fileURL)
                try Task.checkCancellation()
                let outputURL = try MediaTranscriptDocument.outputURL(for: fileURL)
                var estimator = MediaFileTranscriptionEstimator(
                    modelVariant: self.configuration.modelVariant
                )
                let estimatedSeconds = estimator.estimatedSeconds(for: information.duration)
                guard self.confirmMediaFileTranscription(
                    information: information,
                    outputURL: outputURL,
                    estimatedSeconds: estimatedSeconds
                ) else {
                    self.finishMediaFileTranscription(returnToReady: true)
                    return
                }

                self.mediaFileEstimatedSeconds = estimatedSeconds
                self.mediaFileStatusText = "Preparing audio efficiently…"
                self.transition(to: .transcribingFile)
                let startedAt = Date()
                let transcript = try await self.mediaFileTranscriber.transcribe(
                    information,
                    endpoint: endpoint,
                    language: self.configuration.recognitionLanguage
                ) { [weak self] progress in
                    Task { @MainActor in self?.handleMediaFileProgress(progress) }
                }
                try Task.checkCancellation()
                try MediaTranscriptDocument.write(
                    transcript: transcript,
                    source: information,
                    modelName: self.configuration.modelVariant.title,
                    language: self.configuration.recognitionLanguage,
                    to: outputURL
                )
                estimator.record(
                    duration: information.duration,
                    elapsed: Date().timeIntervalSince(startedAt)
                )
                self.lastFileTranscriptURL = outputURL
                self.mediaFileProgress = 1
                self.finishMediaFileTranscription(returnToReady: true)
                NSWorkspace.shared.open(outputURL)
                self.showRecoverableMessage("Transcript saved in Documents → Local Dictation Transcripts → File Transcripts.")
            } catch is CancellationError {
                self.finishMediaFileTranscription(returnToReady: !self.isPowerTransitioning && !self.isQuitting)
            } catch {
                self.finishMediaFileTranscription(returnToReady: !self.isPowerTransitioning && !self.isQuitting)
                if !self.isQuitting { self.showRecoverableMessage(error.localizedDescription) }
            }
        }
    }

    func cancelMediaFileTranscription() {
        guard mediaFileTranscriptionTask != nil else { return }
        mediaFileStatusText = "Canceling…"
        mediaFileProgressTask?.cancel()
        mediaFileTranscriptionTask?.cancel()
        menuBarController?.refresh()
    }

    func openLastFileTranscript() {
        guard let lastFileTranscriptURL else { return }
        NSWorkspace.shared.open(lastFileTranscriptURL)
    }

    func openFileTranscriptsFolder() {
        do {
            NSWorkspace.shared.open(try MediaTranscriptDocument.directory())
        } catch {
            showRecoverableMessage("The file-transcript folder could not be opened: \(error.localizedDescription)")
        }
    }

    func dismissError() {
        overlayController.hide()
        if serverManager.isRunning && realtimeConnected && permissionStatus.allGranted && globalShortcutOperational {
            transition(to: .ready)
        } else if serverManager.isRunning && !permissionStatus.allGranted {
            transition(to: .permissionRequired)
        }
    }

    func cancelDictationFromMenu() {
        cancelDictation()
    }

    func pasteLast() {
        guard let raw = lastRawTranscript,
              let target = insertionService.captureTarget() else { return }
        let processed = TranscriptProcessor.process(
            raw,
            context: target.context,
            removeFillers: settings.removeFillers
        )
        Task {
            do {
                try await insertionService.insert(processed.text, into: target, pressReturn: false)
            } catch {
                transition(to: .error(error.localizedDescription))
            }
        }
    }

    func chooseEngine() {
        guard canEditSpeechConfiguration else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the NeMo-Speech.cpp executable"
        panel.prompt = "Choose Engine"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            saveConfiguration(
                engineURL: url,
                modelURL: configuration.modelURL,
                recognitionLanguage: configuration.recognitionLanguage
            )
        }
    }

    func chooseModel() {
        guard canEditSpeechConfiguration else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the Nemotron Q8 GGUF model"
        panel.prompt = "Choose Model"
        panel.allowedContentTypes = [.data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            saveConfiguration(
                engineURL: configuration.engineURL,
                modelURL: url,
                recognitionLanguage: SpeechModelVariant.identify(url).recommendedLanguage
            )
        }
    }

    func downloadEnglishModel() {
        beginModelDownload(.english)
    }

    func downloadMultilingualModel() {
        beginModelDownload(.multilingual)
    }

    func cancelModelDownload() {
        modelDownloadTask?.cancel()
        modelDownloader.cancel()
    }

    func revealDownloadedModel() {
        let fileURL: URL?
        switch modelDownloadState {
        case .completed(_, let url): fileURL = url
        default: fileURL = nil
        }
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func setRecognitionLanguage(_ language: RecognitionLanguage) {
        guard canEditSpeechConfiguration,
              configuration.modelVariant.supportsLanguageSelection else { return }
        configuration = AppConfiguration(
            engineURL: configuration.engineURL,
            modelURL: configuration.modelURL,
            recognitionLanguage: language
        )
        configuration.persist()
        menuBarController?.refresh()

        guard serverManager.isRunning, realtimeConnected else { return }
        realtimeClient.updateLanguage(
            language.rawValue,
            automaticPunctuation: settings.automaticPunctuation
        )
    }

    func refreshConfigurationAndStart() {
        guard isInstalledInApplications else {
            transition(to: .installationRequired)
            showSetup()
            return
        }
        configuration = AppConfiguration()
        if let issue = configuration.validate() {
            transition(to: .configurationRequired(issue))
        } else {
            setupWindowController?.close()
            scheduleSpeechEngineStart(restart: serverManager.isRunning)
        }
    }

    func showSetup() {
        if setupWindowController == nil {
            setupWindowController = SetupWindowController(coordinator: self)
        }
        refreshPermissions()
        setupWindowController?.showAndActivate()
    }

    func openPlayground() {
        guard let url = serverManager.playgroundURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openModelPage() { NSWorkspace.shared.open(configuration.modelPageURL) }
    func openModelLicense() { NSWorkspace.shared.open(configuration.modelLicenseURL) }
    func openEnglishModelPage() { NSWorkspace.shared.open(AppConfiguration.englishModelPageURL) }
    func openMultilingualModelPage() { NSWorkspace.shared.open(AppConfiguration.multilingualModelPageURL) }
    func openEnglishModelLicense() { NSWorkspace.shared.open(AppConfiguration.englishModelLicenseURL) }
    func openMultilingualModelLicense() { NSWorkspace.shared.open(AppConfiguration.multilingualModelLicenseURL) }
    func openRuntimePage() { NSWorkspace.shared.open(AppConfiguration.runtimePageURL) }
    func openMicrophoneSettings() { permissionManager.openMicrophoneSettings() }
    func openAccessibilitySettings() { permissionManager.openAccessibilitySettings() }
    func openSystemAudioSettings() { permissionManager.openSystemAudioSettings() }

    func showRemovalInstructions() {
        let alert = NSAlert()
        alert.messageText = "Remove Local Dictation"
        alert.informativeText = "Move Local Dictation from Applications to the Trash. To also remove the downloaded model, engine, and settings, choose Remove Local Data below. Saved conversation and media-file transcripts in Documents are kept unless you delete them separately."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Remove Local Data…")
        if alert.runModal() == .alertSecondButtonReturn { confirmAndRemoveLocalData() }
    }

    func confirmAndRemoveLocalData() {
        let supportPath = AppConfiguration.supportDirectory().path
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Remove downloaded model and local data?"
        alert.informativeText = "This permanently removes the speech model and engine files stored by Local Dictation, plus its settings, from:\n\n\(supportPath)\n\nA model you chose from another folder and all transcripts in Documents are left untouched. The application itself remains until you move it to the Trash."
        alert.addButton(withTitle: "Remove and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isQuitting = true
        speechEngineTask?.cancel()
        speechEngineTask = nil
        speechEngineOperationID = nil
        wakeRecoveryTask?.cancel()
        mediaFileTranscriptionTask?.cancel()
        mediaFileProgressTask?.cancel()
        cancelModelDownload()
        cancelDictation()
        hotkeyController.stop()
        realtimeClient.disconnect()
        terminationDeadlineTask?.cancel()
        terminationDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.isQuitting else { return }
            self.serverManager.forceStop()
            NSApp.terminate(nil)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.serverManager.stop(graceNanoseconds: 1_000_000_000)
            do {
                let support = AppConfiguration.supportDirectory()
                if FileManager.default.fileExists(atPath: support.path) {
                    try FileManager.default.removeItem(at: support)
                }
                if let identifier = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: identifier)
                    UserDefaults.standard.synchronize()
                }
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
            NSApp.terminate(nil)
        }
    }

    func quit() {
        guard !isQuitting else { return }
        isQuitting = true
        speechEngineTask?.cancel()
        speechEngineTask = nil
        speechEngineOperationID = nil
        wakeRecoveryTask?.cancel()
        mediaFileTranscriptionTask?.cancel()
        mediaFileProgressTask?.cancel()
        cancelModelDownload()
        cancelDictation()
        hotkeyController.stop()
        realtimeClient.disconnect()
        transition(to: .canceling)
        let activeConversation = conversationSession
        conversationSession = nil
        // Even if transcript finalization or process shutdown stops responding,
        // the app will terminate and applicationWillTerminate will reap the child.
        terminationDeadlineTask?.cancel()
        terminationDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.isQuitting else { return }
            self.logger.error("QUIT_DEADLINE_EXCEEDED forcing termination")
            self.serverManager.forceStop()
            NSApp.terminate(nil)
        }
        Task { [weak self] in
            guard let self else { return }
            if let activeConversation {
                _ = try? await activeConversation.stopAndSave()
            }
            await self.serverManager.stop(graceNanoseconds: 1_000_000_000)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate() {
        speechEngineTask?.cancel()
        wakeRecoveryTask?.cancel()
        terminationDeadlineTask?.cancel()
        mediaFileTranscriptionTask?.cancel()
        mediaFileProgressTask?.cancel()
        permissionMonitorTask?.cancel()
        permissionRequestTask?.cancel()
        targetCaptureTask?.cancel()
        transientMessageTask?.cancel()
        finalizationDelayTask?.cancel()
        conversationTask?.cancel()
        cancelModelDownload()
        audioCapture.cancel()
        conversationSession?.closeForApplicationTermination()
        hotkeyController.stop()
        realtimeClient.disconnect()
        stopPowerMonitoring()
        serverManager.forceStop()
    }

    private func prepareRealtimeConnection() {
        guard let url = serverManager.realtimeURL else { return }
        permissionStatus = permissionManager.status(
            accessibilityOperational: globalShortcutOperational && hotkeyController.isRunning
        )
        realtimeClient.connect(
            to: url,
            automaticPunctuation: settings.automaticPunctuation,
            languageCode: configuration.recognitionLanguage.rawValue
        )
    }

    private func handleRealtimeConnection(_ connected: Bool) {
        realtimeConnected = connected
        speechEngineReady = connected && serverManager.isRunning
        guard !isQuitting, !isPowerTransitioning else { return }
        if connected {
            activateHotkeysIfPossible()
        } else if serverManager.isRunning {
            transition(to: .serverUnavailable("The live transcription connection was interrupted."))
        }
    }

    private func activateHotkeysIfPossible() {
        updatePermissionStatus()
        guard serverManager.isRunning, realtimeConnected else { return }
        guard permissionStatus.microphone else {
            if hotkeyController.isRunning { hotkeyController.stop() }
            globalShortcutOperational = false
            updatePermissionStatus()
            transition(to: .permissionRequired)
            return
        }
        hotkeyController.shortcut = settings.shortcut
        if hotkeyController.isRunning {
            globalShortcutOperational = true
            updatePermissionStatus()
            if state == .permissionRequired { transition(to: .ready) }
            return
        }
        if hotkeyController.start() {
            globalShortcutOperational = true
            updatePermissionStatus()
            transition(to: .ready)
        } else {
            globalShortcutOperational = false
            updatePermissionStatus()
            transition(to: .permissionRequired)
        }
    }

    private func startPermissionMonitoring() {
        permissionMonitorTask?.cancel()
        updatePermissionStatus()
        permissionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                if self.globalShortcutOperational && !self.hotkeyController.isRunning {
                    self.globalShortcutOperational = false
                }
                let previous = self.permissionStatus
                self.updatePermissionStatus()
                if self.permissionStatus != previous
                    || (self.speechEngineReady && !self.globalShortcutOperational) {
                    self.activateHotkeysIfPossible()
                }
            }
        }
    }

    private func startPowerMonitoring() {
        stopPowerMonitoring()
        let center = NSWorkspace.shared.notificationCenter
        workspaceNotificationObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleSystemWillSleep() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleSystemDidWake() }
            }
        ]
    }

    private func stopPowerMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceNotificationObservers.forEach(center.removeObserver)
        workspaceNotificationObservers.removeAll()
    }

    private func handleSystemWillSleep() {
        guard !isQuitting else { return }
        logger.info("SYSTEM_WILL_SLEEP")
        isPowerTransitioning = true
        wakeRecoveryTask?.cancel()
        speechEngineTask?.cancel()
        mediaFileTranscriptionTask?.cancel()
        mediaFileProgressTask?.cancel()
        realtimeClient.disconnect()
        realtimeConnected = false
        speechEngineReady = false
        if state == .recordingConversation {
            stopConversationTranscript()
        } else {
            cancelDictation()
        }
        transition(to: .starting)
    }

    private func handleSystemDidWake() {
        guard !isQuitting else { return }
        logger.info("SYSTEM_DID_WAKE scheduling engine recovery")
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { [weak self] in
            guard let self else { return }
            // Let macOS finish restoring audio devices and give a conversation
            // save a short opportunity to finish before recycling the worker.
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                if self.conversationTask == nil { break }
            }
            guard !Task.isCancelled else { return }
            self.wakeRecoveryTask = nil
            self.scheduleSpeechEngineStart(restart: true)
        }
    }

    private func beginPermissionRequest(for requestedPermission: DictationPermission) {
        guard permissionRequestTask == nil else { return }
        let requestID = UUID()
        permissionRequestID = requestID
        permissionRequestInProgress = true
        permissionRequestTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishPermissionRequest(id: requestID) }

            await self.requestOnce(requestedPermission)
            self.refreshPermissions()
        }
    }

    private func requestOnce(_ permission: DictationPermission) async {
        updatePermissionStatus()
        if permissionStatus.isGranted(permission) { return }

        switch permission {
        case .microphone:
            _ = await permissionManager.requestMicrophone()
        case .accessibility:
            _ = permissionManager.requestAccessibility()
        }
        updatePermissionStatus()
        activateHotkeysIfPossible()
    }

    private func finishPermissionRequest(id: UUID) {
        guard permissionRequestID == id else { return }
        permissionRequestTask = nil
        permissionRequestID = nil
        permissionRequestInProgress = false
    }

    private func updatePermissionStatus() {
        let updated = permissionManager.status(
            accessibilityOperational: globalShortcutOperational && hotkeyController.isRunning
        )
        if updated != permissionStatus { permissionStatus = updated }
        // Audio-only permission has no public preflight API on current macOS.
        // Once the real stream or legacy full-screen preflight verifies it,
        // keep the indicator stable for this launch.
        let updatedSystemAudio = systemAudioPermissionGranted
            || permissionManager.systemAudioGranted
            || systemAudioOperational
        if updatedSystemAudio != systemAudioPermissionGranted {
            systemAudioPermissionGranted = updatedSystemAudio
            menuBarController?.refresh()
        }
    }

    private func resetPrivacyDecision(service: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "org.localdictation.app"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "LocalDictation.PermissionRepair",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "macOS rejected the privacy reset."]
            )
        }
    }

    private func scheduleRelaunch(at applicationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"",
            "local-dictation-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            applicationURL.path
        ]
        try process.run()
    }

    private func startConversationTranscript() {
        guard state == .ready,
              realtimeConnected,
              let realtimeURL = serverManager.realtimeURL else { return }
        guard confirmConversationConsentIfNeeded() else { return }
        transition(to: .startingConversation)
        overlayController.hide()
        conversationTask?.cancel()
        conversationTask = Task { [weak self] in
            guard let self else { return }
            let session = ConversationTranscriptionSession()
            self.conversationSession = session
            session.onError = { [weak self] error in
                self?.handleConversationError(error)
            }

            do {
                let fileURL = try await session.start(
                    realtimeURL: realtimeURL,
                    automaticPunctuation: self.settings.automaticPunctuation,
                    languageCode: self.configuration.recognitionLanguage.rawValue
                )
                try Task.checkCancellation()
                self.conversationTask = nil
                self.systemAudioOperational = true
                self.systemAudioPermissionGranted = true
                self.conversationStartedAt = Date()
                self.transition(to: .recordingConversation)
                self.logger.info("CONVERSATION_STARTED file=\(fileURL.lastPathComponent, privacy: .public)")
            } catch is CancellationError {
                await session.cancel()
                if self.conversationSession === session { self.conversationSession = nil }
                self.conversationStartedAt = nil
                self.conversationTask = nil
                if !self.isQuitting { self.transition(to: .ready) }
            } catch {
                await session.cancel()
                if self.conversationSession === session { self.conversationSession = nil }
                self.conversationStartedAt = nil
                self.systemAudioOperational = false
                self.systemAudioPermissionGranted = false
                self.conversationTask = nil
                self.transition(to: .ready)
                self.showRecoverableMessage(error.localizedDescription)
            }
        }
    }

    private func confirmConversationConsentIfNeeded() -> Bool {
        if UserDefaults.standard.bool(forKey: conversationConsentAcknowledgedKey) { return true }
        let alert = NSAlert()
        alert.messageText = "Before recording a conversation"
        alert.informativeText = "Only record when every participant has agreed and applicable law permits it. Local Dictation saves a text transcript in your Documents folder; it does not save audio or screen video."
        alert.addButton(withTitle: "I Have Permission")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: conversationConsentAcknowledgedKey)
        return true
    }

    private func stopConversationTranscript() {
        guard state == .recordingConversation,
              let session = conversationSession,
              conversationTask == nil else { return }
        conversationStartedAt = nil
        conversationRestartQueued = false
        transition(to: .savingConversation)
        overlayController.hide()
        conversationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fileURL = try await session.stopAndSave()
                self.lastConversationTranscriptURL = fileURL
                if self.conversationSession === session { self.conversationSession = nil }
                self.conversationTask = nil
                self.overlayController.hide()
                let shouldRestart = self.conversationRestartQueued
                self.conversationRestartQueued = false
                self.transition(to: .ready)
                self.menuBarController?.showConversationSaved(at: fileURL)
                if shouldRestart { self.startConversationTranscript() }
            } catch {
                if self.conversationSession === session { self.conversationSession = nil }
                self.conversationStartedAt = nil
                self.conversationTask = nil
                let shouldRestart = self.conversationRestartQueued
                self.conversationRestartQueued = false
                self.transition(to: .ready)
                self.showRecoverableMessage(
                    "The conversation stopped, but the transcript may be incomplete: \(error.localizedDescription)"
                )
                if shouldRestart { self.startConversationTranscript() }
            }
        }
    }

    private func handleConversationError(_ error: Error) {
        guard state == .recordingConversation else { return }
        logger.error("CONVERSATION_ERROR \(error.localizedDescription, privacy: .public)")
        stopConversationTranscript()
    }

    private func handleHotkey(_ event: GlobalHotkeyEvent) {
        switch event {
        case .pushToTalkBegan:
            pushToTalkHeld = true
            if state == .ready { scheduleDictationStart(mode: .pushToTalk) }
        case .pushToTalkEnded:
            pushToTalkHeld = false
            if state == .recording(.pushToTalk) {
                finishDictation()
            } else {
                targetCaptureTask?.cancel()
                targetCaptureTask = nil
            }
        case .toggleHandsFree:
            pushToTalkHeld = false
            targetCaptureTask?.cancel()
            targetCaptureTask = nil
            startOrStopHandsFree()
        case .toggleConversation:
            pushToTalkHeld = false
            targetCaptureTask?.cancel()
            targetCaptureTask = nil
            startOrStopConversationTranscript()
        case .cancel:
            if targetCaptureTask != nil {
                targetCaptureTask?.cancel()
                targetCaptureTask = nil
            } else {
                cancelDictation()
            }
        }
    }

    private func scheduleDictationStart(mode: DictationMode) {
        guard targetCaptureTask == nil, state == .ready else { return }
        targetCaptureTask = Task { [weak self] in
            guard let self else { return }
            await self.beginDictation(mode: mode)
            self.targetCaptureTask = nil
        }
    }

    private func beginDictation(mode: DictationMode) async {
        guard state == .ready, realtimeConnected else { return }
        transientMessageTask?.cancel()
        guard let target = await insertionService.captureTarget(retryingForMilliseconds: 250) else {
            showRecoverableMessage(TextInsertionError.noFocusedTextField.localizedDescription)
            return
        }
        guard !Task.isCancelled,
              mode != .pushToTalk || pushToTalkHeld else { return }
        guard !target.isSecure else {
            showRecoverableMessage(TextInsertionError.secureField.localizedDescription)
            return
        }

        insertionTarget = target
        realtimeClient.beginUtterance()
        do {
            try audioCapture.start { [weak realtimeClient] pcm in
                realtimeClient?.sendAudio(pcm)
            }
            transition(to: .recording(mode))
            overlayController.showListening(mode: mode)
            if mode == .handsFree {
                handsFreeLimitTask?.cancel()
                handsFreeLimitTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30 * 60))
                    guard !Task.isCancelled else { return }
                    self?.finishDictation()
                }
            }
        } catch {
            realtimeClient.cancel()
            insertionTarget = nil
            transition(to: .error(error.localizedDescription))
        }
    }

    private func finishDictation() {
        guard case .recording = state, finalizationDelayTask == nil else { return }
        handsFreeLimitTask?.cancel()
        handsFreeLimitTask = nil
        overlayController.showCapturingTail()
        finalizationDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.releaseTailCaptureMilliseconds))
            guard !Task.isCancelled, let self else { return }
            self.finalizationDelayTask = nil
            self.finishDictationImmediately()
        }
    }

    private func finishDictationImmediately() {
        guard case .recording = state else { return }
        audioCapture.stop()
        transition(to: .finalizing)
        overlayController.showFinalizing()
        realtimeClient.finalize()
    }

    private func cancelDictation(thenStart mode: DictationMode? = nil) {
        guard state == .recording(.pushToTalk)
            || state == .recording(.handsFree)
            || state == .finalizing else { return }
        handsFreeLimitTask?.cancel()
        handsFreeLimitTask = nil
        finalizationDelayTask?.cancel()
        finalizationDelayTask = nil
        pendingModeAfterCancel = mode
        audioCapture.cancel()
        realtimeClient.cancel()
        insertionTarget = nil
        overlayController.hide()
        transition(to: .canceling)
    }

    private func handleRealtimeCleared() {
        guard state == .canceling else { return }
        let nextMode = pendingModeAfterCancel
        pendingModeAfterCancel = nil
        transition(to: realtimeConnected && permissionStatus.allGranted && globalShortcutOperational ? .ready : .permissionRequired)
        if let nextMode, state == .ready { scheduleDictationStart(mode: nextMode) }
    }

    private func handlePartial(_ text: String) {
        guard case .recording = state else { return }
        if settings.showLivePreview { overlayController.updateTranscript(text) }
    }

    private func handleFinal(_ rawTranscript: String) {
        guard state == .finalizing else { return }
        guard !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            insertionTarget = nil
            overlayController.hide()
            transition(to: .ready)
            return
        }
        guard let target = insertionTarget else {
            overlayController.hide()
            transition(to: .error(TextInsertionError.noFocusedTextField.localizedDescription))
            return
        }

        let processed = TranscriptProcessor.process(
            rawTranscript,
            context: target.context,
            removeFillers: settings.removeFillers
        )
        lastRawTranscript = rawTranscript
        lastTranscript = processed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        transition(to: .inserting)

        Task {
            do {
                try await insertionService.insert(
                    processed.text,
                    into: target,
                    pressReturn: processed.shouldPressReturn
                )
                insertionTarget = nil
                overlayController.hide()
                transition(to: .ready)
            } catch {
                insertionTarget = nil
                transition(to: .ready)
                showRecoverableMessage(error.localizedDescription + " The transcript is available in Paste Last.")
            }
        }
    }

    private func handleRealtimeError(_ error: Error) {
        guard !isQuitting else { return }
        finalizationDelayTask?.cancel()
        finalizationDelayTask = nil
        audioCapture.cancel()
        insertionTarget = nil
        overlayController.showMessage(error.localizedDescription)
        transition(to: .error(error.localizedDescription))
    }

    private func showRecoverableMessage(_ message: String) {
        transientMessageTask?.cancel()
        overlayController.showMessage(message)
        transientMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, let self, self.state == .ready else { return }
            self.overlayController.hide()
        }
    }

    private func confirmMediaFileTranscription(
        information: MediaFileInformation,
        outputURL: URL,
        estimatedSeconds: TimeInterval
    ) -> Bool {
        let mediaKind = information.containsVideo ? "video" : "audio"
        let size = ByteCountFormatter.string(
            fromByteCount: information.fileByteCount,
            countStyle: .file
        )
        let alert = NSAlert()
        alert.messageText = "Transcribe “\(information.fileURL.lastPathComponent)”?"
        alert.informativeText = """
        \(information.formatLabel) \(mediaKind) · \(MediaTranscriptDocument.readableDuration(information.duration)) · \(size)

        Estimated time: \(MediaFileTranscriptionEstimator.readableEstimate(estimatedSeconds)). The estimate adapts after completed transcriptions on this Mac.

        Language: \(configuration.recognitionLanguage.title)
        Save as: \(outputURL.path)

        \(MediaFileTranscriptionService.supportedFormatsDescription)

        Processing stays local. Temporary converted audio is deleted when the job finishes or is canceled.
        """
        alert.addButton(withTitle: "Transcribe and Save")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handleMediaFileProgress(_ progress: MediaFileTranscriptionProgress) {
        guard state == .transcribingFile else { return }
        switch progress {
        case .decoding(let fraction):
            mediaFileProgress = min(0.18, max(0, fraction) * 0.18)
            mediaFileStatusText = "Preparing audio…"
            let percent = Int(mediaFileProgress * 100)
            if percent >= lastMediaFileMenuPercent + 5 {
                lastMediaFileMenuPercent = percent
                menuBarController?.refresh()
            }
        case .recognizing:
            mediaFileProgress = max(mediaFileProgress, 0.2)
            mediaFileStatusText = "Transcribing locally…"
            beginMediaFileProgressClock()
        }
    }

    private func beginMediaFileProgressClock() {
        mediaFileProgressTask?.cancel()
        let expected = max(1, mediaFileEstimatedSeconds)
        mediaFileProgressTask = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.state == .transcribingFile else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                self.mediaFileProgress = max(
                    self.mediaFileProgress,
                    min(0.95, 0.2 + (0.75 * elapsed / expected))
                )
                let percent = Int(self.mediaFileProgress * 100)
                if percent >= self.lastMediaFileMenuPercent + 2 {
                    self.lastMediaFileMenuPercent = percent
                    self.menuBarController?.refresh()
                }
            }
        }
    }

    private func finishMediaFileTranscription(returnToReady: Bool) {
        mediaFileProgressTask?.cancel()
        mediaFileProgressTask = nil
        mediaFileTranscriptionTask = nil
        mediaFileName = nil
        mediaFileStatusText = ""
        mediaFileEstimatedSeconds = 0
        lastMediaFileMenuPercent = -1
        if returnToReady {
            if serverManager.isRunning && realtimeConnected {
                transition(
                    to: permissionStatus.allGranted && globalShortcutOperational
                        ? .ready
                        : .permissionRequired
                )
            } else if case .serverUnavailable = state {
                menuBarController?.refresh()
            } else {
                transition(to: .serverUnavailable("The local speech engine is not connected."))
            }
        } else {
            menuBarController?.refresh()
        }
    }

    private func saveConfiguration(
        engineURL: URL,
        modelURL: URL,
        recognitionLanguage: RecognitionLanguage
    ) {
        configuration = AppConfiguration(
            engineURL: engineURL,
            modelURL: modelURL,
            recognitionLanguage: recognitionLanguage
        )
        configuration.persist()
        if let issue = configuration.validate() {
            transition(to: .configurationRequired(issue))
        } else if serverManager.isRunning {
            restartSpeechEngine()
        } else {
            scheduleSpeechEngineStart(restart: false)
        }
    }

    private func scheduleSpeechEngineStart(restart: Bool) {
        guard !isQuitting else { return }
        let previousTask = speechEngineTask
        previousTask?.cancel()
        let operationID = UUID()
        speechEngineOperationID = operationID
        speechEngineTask = Task { [weak self] in
            if let previousTask { await previousTask.value }
            guard !Task.isCancelled, let self, !self.isQuitting,
                  self.speechEngineOperationID == operationID else { return }

            self.configuration = AppConfiguration()
            if let issue = self.configuration.validate() {
                self.isPowerTransitioning = false
                self.transition(to: .configurationRequired(issue))
                self.showSetup()
                self.finishSpeechEngineOperation(operationID)
                return
            }

            do {
                if restart || self.serverManager.isRunning {
                    try await self.serverManager.restart(configuration: self.configuration)
                } else {
                    try await self.serverManager.start(configuration: self.configuration)
                }
                try Task.checkCancellation()
                guard self.speechEngineOperationID == operationID, !self.isQuitting else { return }
                self.isPowerTransitioning = false
                self.prepareRealtimeConnection()
            } catch is CancellationError {
                // A newer operation, sleep transition, or quit owns recovery.
            } catch {
                guard self.speechEngineOperationID == operationID, !self.isQuitting else { return }
                self.isPowerTransitioning = false
                self.speechEngineReady = false
                self.transition(to: .serverUnavailable(error.localizedDescription))
            }
            self.finishSpeechEngineOperation(operationID)
        }
    }

    private func finishSpeechEngineOperation(_ operationID: UUID) {
        guard speechEngineOperationID == operationID else { return }
        speechEngineOperationID = nil
        speechEngineTask = nil
    }

    private func beginModelDownload(_ specification: SpeechModelDownloadSpecification) {
        guard canEditSpeechConfiguration, !modelDownloadState.isDownloading else { return }
        guard confirmModelDownload(specification) else { return }

        modelDownloadState = .downloading(
            specification: specification,
            receivedBytes: 0,
            totalBytes: specification.expectedBytes
        )
        lastModelDownloadMenuPercent = 0
        menuBarController?.refresh()
        modelDownloadTask?.cancel()
        modelDownloadTask = Task { [weak self] in
            guard let self else { return }
            var stagedURLToClean: URL?
            do {
                let destinationURL = specification.destinationURL
                let fileManager = FileManager.default
                let alreadyDownloaded = fileManager.fileExists(atPath: destinationURL.path)
                if alreadyDownloaded {
                    do {
                        try await Task.detached {
                            try ModelDownloader.verifyModel(
                                at: destinationURL,
                                specification: specification
                            )
                        }.value
                        try Task.checkCancellation()
                        completeModelDownload(specification, fileURL: destinationURL)
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // The exact managed destination is corrupt or stale.
                        // Remove it only after verification fails, then replace
                        // it with a newly downloaded and verified file.
                        try fileManager.removeItem(at: destinationURL)
                    }
                }

                let stagedURL = try await modelDownloader.download(specification) { [weak self] received, reportedTotal in
                    Task { @MainActor [weak self] in
                        guard let self,
                              case .downloading(let activeSpecification, _, _) = self.modelDownloadState,
                              activeSpecification == specification else { return }
                        let effectiveTotal = reportedTotal > 0
                            ? reportedTotal
                            : specification.expectedBytes
                        self.modelDownloadState = .downloading(
                            specification: specification,
                            receivedBytes: received,
                            totalBytes: effectiveTotal
                        )
                        let percent = effectiveTotal > 0
                            ? min(100, Int((Double(received) / Double(effectiveTotal)) * 100))
                            : 0
                        if percent == 100 || percent >= self.lastModelDownloadMenuPercent + 5 {
                            self.lastModelDownloadMenuPercent = percent
                            self.menuBarController?.refresh()
                        }
                    }
                }
                stagedURLToClean = stagedURL
                try Task.checkCancellation()
                let installedURL = try await Task.detached {
                    try ModelDownloader.installVerifiedModel(
                        from: stagedURL,
                        specification: specification
                    )
                }.value
                stagedURLToClean = nil
                try Task.checkCancellation()
                completeModelDownload(specification, fileURL: installedURL)
            } catch is CancellationError {
                if let stagedURLToClean { try? FileManager.default.removeItem(at: stagedURLToClean) }
                modelDownloadState = .idle
                modelDownloadTask = nil
                menuBarController?.refresh()
            } catch {
                if let stagedURLToClean { try? FileManager.default.removeItem(at: stagedURLToClean) }
                if (error as NSError).code == NSURLErrorCancelled {
                    modelDownloadState = .idle
                } else {
                    modelDownloadState = .failed(
                        specification: specification,
                        message: error.localizedDescription
                    )
                }
                modelDownloadTask = nil
                menuBarController?.refresh()
            }
        }
    }

    private func completeModelDownload(
        _ specification: SpeechModelDownloadSpecification,
        fileURL: URL
    ) {
        modelDownloadState = .completed(specification: specification, fileURL: fileURL)
        modelDownloadTask = nil
        lastModelDownloadMenuPercent = 100
        menuBarController?.refresh()
        guard canEditSpeechConfiguration else {
            pendingDownloadedModel = (specification, fileURL)
            return
        }
        activateDownloadedModel(specification, fileURL: fileURL)
    }

    private func activateDownloadedModel(
        _ specification: SpeechModelDownloadSpecification,
        fileURL: URL
    ) {
        saveConfiguration(
            engineURL: configuration.engineURL,
            modelURL: fileURL,
            recognitionLanguage: specification.variant.recommendedLanguage
        )
    }

    private func confirmModelDownload(_ specification: SpeechModelDownloadSpecification) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download \(specification.title)?"
        alert.informativeText = "The model is licensed separately from Local Dictation. Review its linked terms before downloading. The verified model will be stored at:\n\n\(specification.destinationURL.path)"
        alert.addButton(withTitle: "Download and Use")
        alert.addButton(withTitle: "View License")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(specification.licenseURL)
            return false
        default:
            return false
        }
    }

    private func transition(to newState: AppState) {
        guard state != newState else { return }
        logger.info("APP_STATE from=\(self.state.label, privacy: .public) to=\(newState.label, privacy: .public)")
        state = newState
        hotkeyController.isDictationActive = newState == .recording(.pushToTalk)
            || newState == .recording(.handsFree)
            || newState == .finalizing
        hotkeyController.isConversationShortcutEnabled = newState == .ready
            || newState == .recordingConversation
            || newState == .savingConversation
        menuBarController?.refresh()
        if newState == .ready, let pendingDownloadedModel {
            self.pendingDownloadedModel = nil
            Task { @MainActor [weak self] in
                self?.activateDownloadedModel(
                    pendingDownloadedModel.0,
                    fileURL: pendingDownloadedModel.1
                )
            }
        }
    }
}
