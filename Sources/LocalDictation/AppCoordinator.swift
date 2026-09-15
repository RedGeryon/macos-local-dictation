import AppKit
import Combine
import Foundation
import OSLog
import UniformTypeIdentifiers

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var state: AppState = .starting {
        didSet { transcriptionActivity.setActive(state.keepsAwakeForTranscription) }
    }
    @Published private(set) var configuration: AppConfiguration
    @Published private(set) var settings: DictationSettings
    @Published private(set) var permissionStatus = DictationPermissionStatus(
        microphone: false,
        accessibility: false
    )
    @Published private(set) var permissionRequestInProgress = false
    @Published private(set) var systemAudioPermissionGranted = false
    @Published private(set) var microphonePermissionState: MicrophonePermissionState = .notDetermined
    @Published private(set) var systemAudioPermissionState: SystemAudioPermissionState = .unknown
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
    @Published private(set) var textToSpeechState: TextToSpeechState = .idle
    @Published private(set) var textToSpeechSettings: TextToSpeechSettings
    @Published private(set) var textToSpeechDraft: TextToSpeechVoiceConfiguration
    @Published private(set) var textToSpeechVoices: [TextToSpeechVoice] = []
    @Published private(set) var lastGeneratedSpeechURL: URL?
    @Published private(set) var textToSpeechProgress: Double?
    @Published private(set) var textToSpeechProgressDetail = ""
    @Published private(set) var textSelectionAccessibilityGranted = false
    @Published private(set) var localFeatureSettings: LocalFeatureSettings
    @Published private(set) var dictationEngineStatus: LocalFeatureRuntimeStatus = .notLoaded {
        didSet { rescheduleIdleUnload() }
    }
    @Published private(set) var readAloudEngineStatus: LocalFeatureRuntimeStatus = .notLoaded {
        didSet { rescheduleIdleUnload() }
    }
    /// The last few quick dictations of this session, newest first.
    @Published private(set) var dictationHistory = DictationHistory()
    @Published private(set) var textToSpeechInstallState: TextToSpeechInstallState = .idle
    @Published private(set) var textToSpeechModelInstallStatus = TextToSpeechModelInstallStatus.unavailable
    @Published private(set) var textToSpeechInstallDetail = ""
    @Published private(set) var installedSpeechModels: [InstalledSpeechModel] = []
    @Published private(set) var installedTextToSpeechFamilies: [InstalledTextToSpeechFamily] = []

    let serverManager: SpeechServerManager
    let permissionManager = PermissionManager()
    private let modelCatalogConfiguration: ModelCatalogConfiguration

    private let transcriptionActivity = TranscriptionActivity()
    private let realtimeClient = RealtimeTranscriptionClient()
    private let modelDownloader = ModelDownloader()
    private let mediaFileTranscriber = MediaFileTranscriptionService()
    private let audioCapture = AudioCaptureService()
    private let hotkeyController = GlobalHotkeyController()
    private let insertionService = TextInsertionService()
    private let overlayController = DictationOverlayController()
    private let textToSpeechServer = TextToSpeechServerManager()
    private let textToSpeechClient = TextToSpeechClient()
    private let textToSpeechPlayback = TextToSpeechPlaybackController()
    private let logger = Logger(subsystem: "org.localdictation.app", category: "App")
    private var menuBarController: MenuBarController?
    private let transcriptNotifier = TranscriptNotifier()
    private var dictationIdleUnloadTask: Task<Void, Never>?
    private var readAloudIdleUnloadTask: Task<Void, Never>?
    private var setupWindowController: SetupWindowController?
    private var insertionTarget: InsertionTarget?
    private var lastRawTranscript: String?
    private var pendingModeAfterCancel: DictationMode?
    private var handsFreeLimitTask: Task<Void, Never>?
    private var targetCaptureTask: Task<Void, Never>?
    private var selectedTextCaptureTask: Task<Void, Never>?
    private var selectedTextCaptureID: UUID?
    private var transientMessageID: UUID?
    private var finalizationDelayTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?
    private var permissionMonitorTask: Task<Void, Never>?
    private var permissionRequestTask: Task<Void, Never>?
    private var permissionRequestID: UUID?
    private var modelDownloadTask: Task<Void, Never>?
    private var speechEngineTask: Task<Void, Never>?
    private var speechEngineOperationID: UUID?
    private var speechModelSelectionOperationID: UUID?
    private var dictationUnloadTask: Task<Void, Never>?
    // This is set before disconnecting the realtime client. Its callback can
    // arrive synchronously, before the stop task has been installed.
    private var dictationUnloading = false
    private var wakeRecoveryTask: Task<Void, Never>?
    private var terminationDeadlineTask: Task<Void, Never>?
    private var mediaFileTranscriptionTask: Task<Void, Never>?
    private var mediaFileProgressTask: Task<Void, Never>?
    private var textToSpeechTask: Task<Void, Never>?
    private var textToSpeechOperationID: UUID?
    private var activeTextToSpeechJobID: String?
    private var activeTextToSpeechTemporaryDirectory: URL?
    private var textToSpeechInstallProcess: Process?
    private var textToSpeechInstallOperationID: UUID?
    private var pendingTextToSpeechDownload: (TextToSpeechModelComponent, TextToSpeechModelChoice)?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var pendingDownloadedModel: (SpeechModelDownloadSpecification, URL)?
    private var lastModelDownloadMenuPercent = -1
    private var lastMediaFileMenuPercent = -1
    private var realtimeConnected = false
    private var expectedRealtimeConnectionID: UUID?
    private var isQuitting = false
    private var isPowerTransitioning = false
    private var restoreDictationAfterWake = false
    private var restoreReadAloudAfterWake = false
    private var pushToTalkHeld = false
    /// What to start as soon as an on-demand model load finishes.
    private enum PendingDictationAction { case handsFree, conversation }
    private var pendingDictationAfterLoad: PendingDictationAction?
    private var systemAudioOperational = false
    private var conversationSession: ConversationTranscriptionSession?
    private let permissionRepairPendingKey = "permissionRepairPending"
    private let conversationConsentAcknowledgedKey = "conversationConsentAcknowledged"
    private static let releaseTailCaptureMilliseconds = 180

    var isInstalledInApplications: Bool {
        ApplicationInstallation.isInApplications(Bundle.main.bundleURL)
    }

    var isTextToSpeechPreview: Bool {
        LocalDictationPreviewIdentity.isPreview()
    }

    var terminationInProgress: Bool { isQuitting }

    var canTranscribeMediaFile: Bool {
        guard localFeatureSettings.dictation.enabled, serverManager.isRunning, serverManager.fileTranscriptionURL != nil else { return false }
        return selectedTextCaptureTask == nil && !textToSpeechState.isActive && (state == .ready || state == .permissionRequired)
    }

    var canUseTextToSpeech: Bool {
        guard localFeatureSettings.readAloud.enabled, !isQuitting, !isPowerTransitioning, !textToSpeechState.isActive,
              targetCaptureTask == nil, selectedTextCaptureTask == nil else { return false }
        switch state {
        case .recording, .startingConversation, .recordingConversation, .savingConversation,
             .inspectingMedia, .transcribingFile, .finalizing, .inserting, .canceling:
            return false
        default:
            return true
        }
    }

    var isTextToSpeechOperationActive: Bool {
        textToSpeechState.isActive || selectedTextCaptureTask != nil
    }
    var isDictationEngineUnloading: Bool { dictationUnloading }

    /// Reading a selection needs the Accessibility API itself. A running event tap is
    /// useful for shortcuts, but does not prove this separate permission is granted.
    var accessibilityGrantedForSelectedText: Bool {
        textSelectionAccessibilityGranted
    }

    var textToSpeechStatusLabel: String {
        selectedTextCaptureTask != nil ? "Checking selected text…" : textToSpeechState.label
    }

    /// The compact status label stays readable in the menu; Models & Startup
    /// can show this diagnostic beneath it when a local engine needs attention.
    var dictationEngineStatusDetail: String? {
        guard case .error(let message) = dictationEngineStatus else { return nil }
        return message
    }

    var textToSpeechIssueMessage: String? {
        switch textToSpeechState {
        case .unavailable(let message), .error(let message): return message
        default: return nil
        }
    }

    var textToSpeechSetupGuidance: String {
        switch textToSpeechState {
        case .unavailable:
            return "Open Models & Startup to download the selected voice model. Then choose Load Now or try reading again."
        case .error:
            return "Open Models & Startup to check the selected voice-model components, then choose Load Now or try reading again."
        default:
            return ""
        }
    }

    var textToSpeechRecoveryActionTitle: String {
        switch textToSpeechState {
        case .unavailable: return "Set Up or Retry Text to Speech…"
        case .error: return "Retry Text to Speech…"
        default: return "Text to Speech…"
        }
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

    init(serverManager: SpeechServerManager = SpeechServerManager(), modelCatalogConfiguration: ModelCatalogConfiguration = .live()) {
        self.serverManager = serverManager
        self.modelCatalogConfiguration = modelCatalogConfiguration
        configuration = modelCatalogConfiguration.appConfiguration ?? AppConfiguration(defaults: modelCatalogConfiguration.defaults)
        settings = DictationSettings(defaults: modelCatalogConfiguration.defaults)
        let loadedTTSSettings = TextToSpeechSettings(defaults: modelCatalogConfiguration.defaults)
        let loadedFeatures = LocalFeatureSettings.load(defaults: modelCatalogConfiguration.defaults)
        textToSpeechSettings = loadedTTSSettings
        textToSpeechDraft = loadedTTSSettings.activeVoiceConfiguration
        localFeatureSettings = loadedFeatures
        dictationEngineStatus = loadedFeatures.dictation.enabled ? .notLoaded : .disabled
        readAloudEngineStatus = loadedFeatures.readAloud.enabled ? .notLoaded : .disabled
        if let initialState = modelCatalogConfiguration.initialState { state = initialState }
        self.serverManager.onStateChange = { [weak self] state in
            guard let self, !self.isQuitting, self.localFeatureSettings.dictation.enabled else { return }
            self.transition(to: state)
        }
        realtimeClient.onPartial = { [weak self] text in self?.handlePartial(text) }
        realtimeClient.onFinal = { [weak self] text in self?.handleFinal(text) }
        realtimeClient.onErrorEvent = { [weak self] error, connectionID in
            self?.handleRealtimeError(error, connectionID: connectionID)
        }
        realtimeClient.onConnectionEvent = { [weak self] connected, connectionID in
            self?.handleRealtimeConnection(connected, connectionID: connectionID)
        }
        realtimeClient.onCleared = { [weak self] in self?.handleRealtimeCleared() }
        hotkeyController.onEvent = { [weak self] event in self?.handleHotkey(event) }
    }

    func start() {
        TextToSpeechStorage.capturePreviewDirectories()
        removeStaleTextToSpeechTemporaryFiles()
        refreshTextToSpeechInstallStatus()
        refreshInstalledSpeechModels()
        menuBarController = MenuBarController(coordinator: self)
        startPermissionMonitoring()
        startPowerMonitoring()
        transition(to: .starting)
        activateHotkeysIfPossible()

        guard isInstalledInApplications || isTextToSpeechPreview else {
            transition(to: .installationRequired)
            showSetup()
            return
        }

        let shouldResumePermissionRepair = UserDefaults.standard.bool(forKey: permissionRepairPendingKey)
        if shouldResumePermissionRepair {
            UserDefaults.standard.removeObject(forKey: permissionRepairPendingKey)
            showSetup()
        }

        let dictationConfigurationIssue = localFeatureSettings.dictation.enabled
            ? configuration.validate()
            : nil
        if let dictationConfigurationIssue {
            // TTS has its own runtime and may still be loaded below. Do not let
            // a missing ASR model turn the app into a stuck startup gate.
            dictationEngineStatus = .error(dictationConfigurationIssue.message)
            transition(to: .configurationRequired(dictationConfigurationIssue))
            showSetup()
        }

        if localFeatureSettings.dictation.enabled,
           dictationConfigurationIssue == nil,
           localFeatureSettings.dictation.loadAtStartup {
            loadDictationEngine()
        } else if dictationConfigurationIssue == nil {
            transition(to: .ready)
        }
        if localFeatureSettings.readAloud.enabled && localFeatureSettings.readAloud.loadAtStartup {
            loadReadAloudEngine()
        }
    }

    func setDictationFeature(enabled: Bool, loadAtStartup: Bool) {
        let wasEnabled = localFeatureSettings.dictation.enabled
        localFeatureSettings.dictation.enabled = enabled
        localFeatureSettings.dictation.loadAtStartup = loadAtStartup
        localFeatureSettings.persist(defaults: modelCatalogConfiguration.defaults)
        if enabled && !wasEnabled {
            dictationEngineStatus = .notLoaded
        } else if !enabled {
            unloadDictationEngine()
        }
        if enabled { activateHotkeysIfPossible() }
        refreshHotkeyGates()
        menuBarController?.refresh()
    }

    func setReadAloudFeature(enabled: Bool, loadAtStartup: Bool, model: TextToSpeechModelChoice) {
        guard !isTextToSpeechOperationActive || !enabled else { return }
        let wasEnabled = localFeatureSettings.readAloud.enabled
        let selectedModelChanged = localFeatureSettings.readAloud.model != model
        localFeatureSettings.readAloud.enabled = enabled
        localFeatureSettings.readAloud.loadAtStartup = loadAtStartup
        localFeatureSettings.readAloud.model = model
        localFeatureSettings.persist(defaults: modelCatalogConfiguration.defaults)
        if !enabled || selectedModelChanged {
            unloadReadAloudEngine()
        } else if enabled && !wasEnabled {
            readAloudEngineStatus = .notLoaded
        }
        refreshTextToSpeechInstallStatus()
        if enabled { activateHotkeysIfPossible() }
        refreshHotkeyGates()
        menuBarController?.refresh()
    }

    // MARK: - Idle unloading

    func setDictationIdleUnload(minutes: IdleUnloadMinutes?) {
        localFeatureSettings.dictation.idleUnloadMinutes = minutes
        localFeatureSettings.persist(defaults: modelCatalogConfiguration.defaults)
        rescheduleIdleUnload()
    }

    func setReadAloudIdleUnload(minutes: IdleUnloadMinutes?) {
        localFeatureSettings.readAloud.idleUnloadMinutes = minutes
        localFeatureSettings.persist(defaults: modelCatalogConfiguration.defaults)
        rescheduleIdleUnload()
    }

    /// Re-arms the idle timers from the current state. Called whenever either
    /// feature changes state, so any activity restarts the countdown and a
    /// busy feature is never unloaded underneath its work.
    private func rescheduleIdleUnload() {
        dictationIdleUnloadTask?.cancel()
        dictationIdleUnloadTask = nil
        readAloudIdleUnloadTask?.cancel()
        readAloudIdleUnloadTask = nil
        guard !isQuitting, !isPowerTransitioning else { return }

        let dictationMinutes = localFeatureSettings.dictation.idleUnloadMinutes
        if IdleUnloadPolicy.shouldSchedule(
            minutes: dictationMinutes,
            engineReady: dictationEngineStatus == .ready,
            busy: state != .ready || targetCaptureTask != nil
        ), let minutes = dictationMinutes {
            dictationIdleUnloadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled, let self, self.state == .ready, self.dictationEngineStatus == .ready,
                      self.targetCaptureTask == nil, !self.isQuitting, !self.isPowerTransitioning else { return }
                self.logger.info("IDLE_UNLOAD feature=dictation minutes=\(minutes, privacy: .public)")
                self.unloadDictationEngine()
            }
        }

        let readAloudMinutes = localFeatureSettings.readAloud.idleUnloadMinutes
        if IdleUnloadPolicy.shouldSchedule(
            minutes: readAloudMinutes,
            engineReady: readAloudEngineStatus == .ready,
            busy: isTextToSpeechOperationActive || textToSpeechInstallState.isActive
        ), let minutes = readAloudMinutes {
            readAloudIdleUnloadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled, let self, self.readAloudEngineStatus == .ready,
                      !self.isTextToSpeechOperationActive, !self.textToSpeechInstallState.isActive,
                      !self.isQuitting, !self.isPowerTransitioning else { return }
                self.logger.info("IDLE_UNLOAD feature=readAloud minutes=\(minutes, privacy: .public)")
                self.unloadReadAloudEngine()
            }
        }
    }

    // MARK: - Login item

    var loginItemState: LoginItemManager.State { LoginItemManager.state }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
        } catch {
            showRecoverableMessage("Could not update the login item: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    func openLoginItemsSettings() { LoginItemManager.openSystemSettings() }

    /// Explicit load action for the ASR engine. Enabled engines are never loaded
    /// merely because the settings window was opened.
    func loadDictationEngine() {
        guard localFeatureSettings.dictation.enabled, !isQuitting, !isPowerTransitioning else { return }
        guard dictationUnloadTask == nil else { return }
        guard speechEngineTask == nil, !serverManager.isRunning else {
            if serverManager.isRunning { dictationEngineStatus = .ready }
            return
        }
        scheduleSpeechEngineStart(restart: false)
    }

    func unloadDictationEngine() {
        pendingDictationAfterLoad = nil
        dictationUnloading = true
        expectedRealtimeConnectionID = nil
        speechEngineTask?.cancel()
        speechEngineTask = nil
        speechEngineOperationID = nil
        audioCapture.cancel()
        targetCaptureTask?.cancel()
        targetCaptureTask = nil
        mediaFileTranscriptionTask?.cancel()
        if state == .recordingConversation { stopConversationTranscript() }
        realtimeClient.cancel()
        realtimeClient.disconnect()
        realtimeConnected = false
        speechEngineReady = false
        dictationUnloadTask?.cancel()
        dictationUnloadTask = Task { [weak self, serverManager] in
            await serverManager.stop(graceNanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.dictationUnloadTask = nil
            self.dictationUnloading = false
            self.refreshHotkeyGates()
        }
        dictationEngineStatus = localFeatureSettings.dictation.enabled ? .notLoaded : .disabled
        if !isQuitting && !isPowerTransitioning { transition(to: .ready) }
    }

    /// Explicit load action for the selected TTS model. The worker's preload
    /// endpoint warms the model, rather than only listing voices.
    func loadReadAloudEngine() {
        guard localFeatureSettings.readAloud.enabled, !isQuitting, !isPowerTransitioning,
              !textToSpeechState.isActive, selectedTextCaptureTask == nil else { return }
        loadTextToSpeechVoicesIfNeeded()
    }

    func unloadReadAloudEngine() {
        cancelTextToSpeechInstall()
        cancelSelectedTextCapture()
        textToSpeechTask?.cancel()
        textToSpeechPlayback.stop()
        textToSpeechOperationID = nil
        activeTextToSpeechJobID = nil
        textToSpeechVoices = []
        textToSpeechProgress = nil
        textToSpeechProgressDetail = ""
        if let endpoint = textToSpeechServer.endpoint, let token = textToSpeechServer.token {
            Task { [textToSpeechClient] in await textToSpeechClient.unloadModel(endpoint: endpoint, token: token) }
        }
        textToSpeechServer.forceStop()
        readAloudEngineStatus = localFeatureSettings.readAloud.enabled ? .notLoaded : .disabled
        transitionTextToSpeech(to: .idle)
    }

    func refreshTextToSpeechInstallStatus() {
        let families = TextToSpeechModelCatalog.installedFamilies(modelsDirectory: textToSpeechModelsDirectory(), runtimeDirectory: textToSpeechRuntimeDirectory())
        installedTextToSpeechFamilies = families.filter(\.customVoiceInstalled)
        let selected = families.first { $0.model == localFeatureSettings.readAloud.model }
        textToSpeechModelInstallStatus = selected.map { .init(runtimeInstalled: $0.runtimeInstalled, customVoiceInstalled: $0.customVoiceInstalled, voiceDesignInstalled: $0.voiceDesignInstalled, baseInstalled: $0.baseInstalled) } ?? .unavailable
    }

    var availableTextToSpeechComponents: [TextToSpeechModelComponent] { TextToSpeechModelComponent.allCases }

    func refreshInstalledSpeechModels() {
        installedSpeechModels = AppConfiguration.installedSpeechModels(currentModelURL: configuration.modelURL, defaults: modelCatalogConfiguration.defaults, supportDirectory: modelCatalogConfiguration.supportDirectory)
    }

    func selectInstalledSpeechModel(_ model: InstalledSpeechModel) {
        guard canEditSpeechConfiguration, AppConfiguration.isGGUF(model.url) else { return }
        if AppConfiguration.isGGUF(configuration.modelURL) {
            AppConfiguration.rememberSpeechModel(configuration.modelURL, defaults: modelCatalogConfiguration.defaults)
        }
        AppConfiguration.rememberSpeechModel(model.url, defaults: modelCatalogConfiguration.defaults)
        let changed = configuration.modelURL.standardizedFileURL != model.url.standardizedFileURL
        if changed { unloadDictationEngine() }
        configuration = AppConfiguration(engineURL: configuration.engineURL, modelURL: model.url, recognitionLanguage: model.variant.recommendedLanguage)
        configuration.persist(to: modelCatalogConfiguration.defaults)
        refreshInstalledSpeechModels()
        guard changed, localFeatureSettings.dictation.enabled else { return }
        // Stop has asynchronous cleanup. Only the latest picker choice may
        // launch after it completes, so quick successive selections cannot
        // resurrect an earlier model.
        let selectionID = UUID()
        speechModelSelectionOperationID = selectionID
        Task { [weak self] in
            guard let self else { return }
            if let unload = self.dictationUnloadTask { await unload.value }
            guard self.speechModelSelectionOperationID == selectionID,
                  self.localFeatureSettings.dictation.enabled,
                  !self.isDictationEngineUnloading else { return }
            self.speechModelSelectionOperationID = nil
            self.loadDictationEngine()
        }
    }

    func selectInstalledTextToSpeechFamily(_ family: InstalledTextToSpeechFamily) {
        guard family.customVoiceInstalled, !isTextToSpeechOperationActive else { return }
        let changed = localFeatureSettings.readAloud.model != family.model
        setReadAloudFeature(
            enabled: localFeatureSettings.readAloud.enabled,
            loadAtStartup: localFeatureSettings.readAloud.loadAtStartup,
            model: family.model
        )
        if changed, localFeatureSettings.readAloud.enabled { loadReadAloudEngine() }
    }

    func installTextToSpeechRuntime() {
        runTextToSpeechInstaller(kind: .settingUpRuntime, arguments: ["setup-tts-runtime.sh"])
    }

    func downloadTextToSpeechModel(_ component: TextToSpeechModelComponent) {
        downloadTextToSpeechModel(component, for: localFeatureSettings.readAloud.model)
    }

    func downloadTextToSpeechModel(_ component: TextToSpeechModelComponent, for model: TextToSpeechModelChoice) {
        guard textToSpeechModelInstallStatus.runtimeInstalled else {
            // One explicit Download action may install the isolated runtime and
            // then the requested component. Capture the model now so a later
            // settings change cannot redirect the queued download.
            pendingTextToSpeechDownload = (component, model)
            runTextToSpeechInstaller(kind: .settingUpRuntime, arguments: ["setup-tts-runtime.sh"])
            return
        }
        runTextToSpeechInstaller(kind: .downloading(component, model), arguments: ["download-tts-models.sh", "--model", component.downloadArgument(for: model)])
    }

    func cancelTextToSpeechInstall() {
        pendingTextToSpeechDownload = nil
        guard let process = textToSpeechInstallProcess, process.isRunning else { return }
        textToSpeechInstallState = .canceling
        // The shell may be waiting on Python or pip. Signal direct children as
        // well, and leave the operation token in place until termination so a
        // late callback cannot report a completed download.
        let childKiller = Process()
        childKiller.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        childKiller.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        if (try? childKiller.run()) != nil { childKiller.waitUntilExit() }
        process.terminate()
        textToSpeechInstallDetail = "Canceling download…"
    }

    private func textToSpeechRuntimeDirectory() -> URL {
        modelCatalogConfiguration.ttsRuntimeDirectory
    }

    private func textToSpeechModelsDirectory() -> URL {
        modelCatalogConfiguration.ttsModelsDirectory
    }

    private func runTextToSpeechInstaller(kind: TextToSpeechInstallState, arguments: [String]) {
        guard !textToSpeechInstallState.isActive,
              let assetRoot = textToSpeechAssetRoot() else {
            if textToSpeechAssetRoot() == nil { textToSpeechInstallState = .failed("The bundled TTS installer assets are unavailable.") }
            return
        }
        let script = assetRoot.appendingPathComponent("scripts").appendingPathComponent(arguments[0])
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            textToSpeechInstallState = .failed("The bundled TTS installer is unavailable.")
            return
        }
        let id = UUID()
        let output = Pipe(); let errors = Pipe(); let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments.dropFirst()
        var environment = ProcessInfo.processInfo.environment
        environment["LOCAL_DICTATION_TTS_ASSET_DIR"] = assetRoot.path
        environment["LOCAL_DICTATION_TTS_RUNTIME_DIR"] = textToSpeechRuntimeDirectory().path
        environment["LOCAL_DICTATION_TTS_MODEL_DIR"] = textToSpeechModelsDirectory().path
        process.environment = environment; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData; guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            Task { @MainActor in if self?.textToSpeechInstallOperationID == id { self?.textToSpeechInstallDetail = text } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData; guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            Task { @MainActor in if self?.textToSpeechInstallOperationID == id { self?.textToSpeechInstallDetail = text } }
        }
        process.terminationHandler = { [weak self] child in Task { @MainActor in
            guard let self, self.textToSpeechInstallOperationID == id else { return }
            output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
            self.textToSpeechInstallProcess = nil; self.textToSpeechInstallOperationID = nil
            let wasCanceled = self.textToSpeechInstallState == .canceling
            self.refreshTextToSpeechInstallStatus()
            if wasCanceled { self.pendingTextToSpeechDownload = nil; self.textToSpeechInstallState = .idle; return }
            guard child.terminationStatus == 0 else {
                self.pendingTextToSpeechDownload = nil
                self.textToSpeechInstallState = self.textToSpeechInstallState == .canceling
                    ? .idle
                    : .failed(self.textToSpeechInstallDetail.isEmpty ? "Installer exited with status \(child.terminationStatus)." : self.textToSpeechInstallDetail)
                return
            }
            if case .settingUpRuntime = kind, !self.textToSpeechModelInstallStatus.runtimeInstalled {
                self.pendingTextToSpeechDownload = nil
                self.textToSpeechInstallState = .failed("The TTS runtime installer finished without a valid runtime.")
                return
            }
            if let (component, model) = self.pendingTextToSpeechDownload {
                self.pendingTextToSpeechDownload = nil
                self.textToSpeechInstallState = .idle
                self.runTextToSpeechInstaller(kind: .downloading(component, model), arguments: ["download-tts-models.sh", "--model", component.downloadArgument(for: model)])
            } else {
                if case .downloading(let component, let model) = kind {
                    let allFamilies = TextToSpeechModelCatalog.installedFamilies(modelsDirectory: self.textToSpeechModelsDirectory(), runtimeDirectory: self.textToSpeechRuntimeDirectory())
                    guard let family = allFamilies.first(where: { $0.model == model }),
                          (component != .customVoice || family.customVoiceInstalled),
                          (component != .voiceDesign || family.voiceDesignInstalled),
                          (component != .base || family.baseInstalled) else {
                        self.textToSpeechInstallState = .failed("The requested voice-model component was not verified after download.")
                        return
                    }
                }
                self.textToSpeechInstallState = .completed("Installation complete.")
                if case .downloading(let component, let model) = kind {
                    let selected = TextToSpeechModelCatalog.selectionAfterCompletedDownload(
                        component: component, downloaded: model,
                        current: self.localFeatureSettings.readAloud.model,
                        installed: self.installedTextToSpeechFamilies
                    )
                    guard selected != self.localFeatureSettings.readAloud.model else { return }
                    // First usable preset family becomes the choice; an already
                    // valid user selection is never replaced by a download.
                    self.setReadAloudFeature(enabled: self.localFeatureSettings.readAloud.enabled, loadAtStartup: self.localFeatureSettings.readAloud.loadAtStartup, model: selected)
                }
            }
        } }
        textToSpeechInstallProcess = process; textToSpeechInstallOperationID = id; textToSpeechInstallState = kind; textToSpeechInstallDetail = "Starting…"
        do { try process.run() }
        catch { textToSpeechInstallProcess = nil; textToSpeechInstallOperationID = nil; textToSpeechInstallState = .failed(error.localizedDescription) }
    }

    private func textToSpeechAssetRoot() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("TTSAssets", isDirectory: true)
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".")
        return FileManager.default.fileExists(atPath: development.appendingPathComponent("scripts/setup-tts-runtime.sh").path) ? development : nil
    }

    func restartSpeechEngine() {
        guard localFeatureSettings.dictation.enabled else { return }
        cancelDictation()
        realtimeClient.disconnect()
        realtimeConnected = false
        speechEngineReady = false
        scheduleSpeechEngineStart(restart: true)
    }

    func requestMicrophonePermission() {
        guard isInstalledInApplications || isTextToSpeechPreview else { return showSetup() }
        beginPermissionRequest(for: .microphone)
    }

    func requestAccessibilityPermission() {
        requestAccessibilityPermission(openSettingsIfNeeded: false)
    }

    private func requestAccessibilityPermission(openSettingsIfNeeded: Bool) {
        guard isInstalledInApplications || isTextToSpeechPreview else { return showSetup() }
        let shouldOpenSettings = openSettingsIfNeeded && !permissionManager.accessibilityGranted
        beginPermissionRequest(for: .accessibility)
        if shouldOpenSettings {
            if !permissionManager.openAccessibilitySettings() {
                showRecoverableMessage("System Settings could not open Accessibility privacy settings.")
            }
        }
    }

    func enableTextToSpeechReadShortcuts() {
        setTextToSpeechShortcutsEnabled(true)
        showTextToSpeechVoiceSettings()
        requestAccessibilityPermission(openSettingsIfNeeded: true)
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

    /// What System Settings currently says about Screen & System Audio Recording.
    /// It is only a hint: the app treats the permission as verified after a real capture.
    var systemAudioAllowedInSystemSettings: Bool { permissionManager.systemAudioGranted }

    func refreshPermissions() {
        updatePermissionStatus()
        activateHotkeysIfPossible()
    }

    func setShortcutBindings(_ bindings: ShortcutBindings) {
        settings.bindings = bindings
        settings.persist()
        hotkeyController.bindings = bindings
        refreshHotkeyGates()
        menuBarController?.refresh()
    }

    func resetShortcutBindings() {
        setShortcutBindings(.standard)
    }

    /// Silences the event tap while the Settings window is recording a new shortcut.
    func setShortcutRecordingActive(_ active: Bool) {
        hotkeyController.isSuspended = active
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

    func setAutomaticPunctuation(_ enabled: Bool) {
        settings.automaticPunctuation = enabled
        settings.persist()
        if realtimeConnected { realtimeClient.updateLanguage(configuration.recognitionLanguage.rawValue, automaticPunctuation: enabled) }
        menuBarController?.refresh()
    }

    func setTextToSpeechShortcutsEnabled(_ enabled: Bool) {
        textToSpeechSettings.shortcutsEnabled = enabled
        textToSpeechSettings.persist()
        refreshHotkeyGates()
        menuBarController?.refresh()
    }

    func updateTextToSpeechDraft(id: String, voicePrompt: String, pronunciationOverridesText: String) {
        textToSpeechDraft = TextToSpeechVoiceConfiguration(
            voiceID: id,
            voicePrompt: voicePrompt,
            pronunciationOverridesText: pronunciationOverridesText
        )
    }

    /// Selects a saved voice profile for editing or previewing. It does not change
    /// the voice used by the global read shortcuts until the user saves it.
    func selectTextToSpeechDraftVoice(_ voiceID: String) {
        textToSpeechDraft = textToSpeechSettings.savedVoiceConfiguration(for: voiceID)
    }

    func textToSpeechSavedConfiguration(for voiceID: String) -> TextToSpeechVoiceConfiguration {
        textToSpeechSettings.savedVoiceConfiguration(for: voiceID)
    }

    func hasSavedTextToSpeechVoice(_ voiceID: String) -> Bool {
        textToSpeechSettings.hasSavedVoiceConfiguration(for: voiceID)
    }

    func saveTextToSpeechDraftAsCurrentVoice() throws {
        try textToSpeechSettings.saveAndUseVoiceConfiguration(textToSpeechDraft)
        textToSpeechDraft = textToSpeechSettings.activeVoiceConfiguration
        textToSpeechSettings.persist()
        menuBarController?.refresh()
    }

    func useSavedTextToSpeechVoice(_ voiceID: String) {
        let draftWasClean = textToSpeechDraft == textToSpeechSettings.activeVoiceConfiguration
        textToSpeechSettings.useSavedVoice(voiceID)
        // A menu choice changes the global shortcut voice immediately. Keep a
        // separate, unsaved editor draft intact so a quick menu action cannot
        // discard text the user has typed in the Voice page.
        if draftWasClean {
            textToSpeechDraft = textToSpeechSettings.activeVoiceConfiguration
        }
        textToSpeechSettings.persist()
        menuBarController?.refresh()
    }

    func startOrStopHandsFree() {
        guard localFeatureSettings.dictation.enabled else { return }
        switch state {
        case .recording(.handsFree):
            finishDictation()
        case .recording(.pushToTalk):
            cancelDictation(thenStart: .handsFree)
        case .ready:
            guard !textToSpeechState.isActive else { return }
            if loadDictationEngineOnDemand() {
                pendingDictationAfterLoad = .handsFree
                showRecoverableMessage("Loading the speech model… Long Dictation starts as soon as it is ready.")
                return
            }
            scheduleDictationStart(mode: .handsFree)
        default:
            break
        }
    }

    /// Starts loading an unloaded (or failed) speech model. Returns true when a
    /// load was started, so the caller can wait for `resumeDictationAfterLoad`.
    @discardableResult
    private func loadDictationEngineOnDemand() -> Bool {
        switch dictationEngineStatus {
        case .notLoaded, .error:
            guard localFeatureSettings.dictation.enabled, state == .ready else { return false }
            loadDictationEngine()
            return true
        default:
            return false
        }
    }

    /// Continues what the user asked for while the model was loading: a held
    /// push-to-talk key, a Long Dictation press, or a conversation start.
    private func resumeDictationAfterLoad() {
        let pending = pendingDictationAfterLoad
        pendingDictationAfterLoad = nil
        guard state == .ready, dictationEngineStatus == .ready, !isTextToSpeechOperationActive else { return }
        if pushToTalkHeld {
            dismissTransientMessage()
            scheduleDictationStart(mode: .pushToTalk)
            return
        }
        switch pending {
        case .handsFree:
            dismissTransientMessage()
            scheduleDictationStart(mode: .handsFree)
        case .conversation:
            dismissTransientMessage()
            startConversationTranscript()
        case nil:
            break
        }
    }

    func startOrStopConversationTranscript() {
        guard localFeatureSettings.dictation.enabled else { return }
        switch state {
        case .recordingConversation:
            stopConversationTranscript()
        case .savingConversation:
            conversationRestartQueued.toggle()
            menuBarController?.refresh()
        case .ready:
            if loadDictationEngineOnDemand() {
                pendingDictationAfterLoad = .conversation
                showRecoverableMessage("Loading the speech model… the conversation transcript starts as soon as it is ready.")
                return
            }
            startConversationTranscript()
        default:
            break
        }
    }

    func requestSystemAudioPermission() {
        guard isInstalledInApplications || isTextToSpeechPreview else { return showSetup() }
        systemAudioPermissionState = .requested
        if !permissionManager.openSystemAudioSettings() {
            showRecoverableMessage("System Settings could not open Screen & System Audio Recording. Open Privacy & Security manually.")
        }
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
        guard localFeatureSettings.dictation.enabled, canTranscribeMediaFile,
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
                self.showRecoverableMessage("Transcript saved in Documents → Local Dictation Transcripts → \(outputURL.deletingLastPathComponent().lastPathComponent).")
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
        dismissTransientMessage()
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

    /// Test seam: records a finished dictation without running the engine.
    func recordDictationForTesting(rawTranscript: String, text: String) {
        dictationHistory.record(rawTranscript: rawTranscript, text: text)
    }

    /// Inserts an earlier dictation at the current cursor, re-processed for
    /// the target field just like Paste Last.
    func insertRecentDictation(id: UUID) {
        guard let entry = dictationHistory.entry(id: id),
              let target = insertionService.captureTarget() else { return }
        let processed = TranscriptProcessor.process(
            entry.rawTranscript,
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

    func showTextToSpeechWindow() {
        showTextToSpeechVoiceSettings()
    }

    func showTextToSpeechVoiceSettings() {
        showSetup()
        setupWindowController?.showReadAloudVoice()
    }

    func showTextToSpeechAudioCreator() {
        showSetup()
        setupWindowController?.showReadAloudAudio()
    }

    func showTextToSpeechSetup() {
        showSetup()
        setupWindowController?.showReadAloudSetup()
    }

    func retryTextToSpeechSetup() {
        guard !isTextToSpeechOperationActive else { return }
        textToSpeechTask?.cancel()
        textToSpeechVoices = []
        textToSpeechOperationID = nil
        textToSpeechServer.forceStop()
        transitionTextToSpeech(to: .idle)
        loadReadAloudEngine()
    }

    func readSelectedText() {
        guard accessibilityGrantedForSelectedText else {
            let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
            logger.info("TTS_SELECTION_CAPTURE blocked raw_ax_trusted=false")
            showTextToSpeechVoiceSettings()
            showRecoverableMessage("Allow Accessibility for \(appName) to read selected text.")
            return
        }
        guard TextToSpeechSelectionCaptureGate.canBegin(
            canUseTextToSpeech: ensureTextToSpeechAvailableForNewWork(),
            capturePending: selectedTextCaptureTask != nil
        ) else {
            logger.info("TTS_SELECTION_CAPTURE not_started can_use=\(self.canUseTextToSpeech, privacy: .public) pending=\(self.selectedTextCaptureTask != nil, privacy: .public)")
            return
        }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        // Capture the saved voice before selection retrieval awaits browser
        // Accessibility. A later editor save must apply only to the next job.
        let configuration = textToSpeechSettings.activeVoiceConfiguration
        logger.info(
            "TTS_SELECTION_CAPTURE started raw_ax_trusted=\(self.permissionManager.accessibilityGranted, privacy: .public) tap_running=\(self.hotkeyController.isRunning, privacy: .public) frontmost=\(frontmostBundleID, privacy: .public)"
        )
        let captureID = UUID()
        selectedTextCaptureID = captureID
        selectedTextCaptureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.insertionService.selectedText { [weak self] in
                    self?.showRecoverableMessage("Release shortcut to read selected text")
                }
                guard self.selectedTextCaptureID == captureID else { return }
                self.logger.info("TTS_SELECTION_CAPTURE succeeded character_count=\(text.count, privacy: .public)")
                self.clearSelectedTextCapture(id: captureID)
                self.dismissTransientMessage()
                guard self.ensureTextToSpeechAvailableForNewWork() else { return }
                try self.startTextToSpeechReadback(text: text, configuration: configuration)
            } catch is CancellationError {
                self.logger.info("TTS_SELECTION_CAPTURE cancelled")
                self.clearSelectedTextCapture(id: captureID)
            } catch {
                guard self.selectedTextCaptureID == captureID else { return }
                self.logger.info("TTS_SELECTION_CAPTURE failed outcome=\(Self.selectionCaptureOutcome(error), privacy: .public)")
                self.clearSelectedTextCapture(id: captureID)
                self.showRecoverableMessage(error.localizedDescription)
            }
        }
        refreshTextToSpeechHotkeys()
        menuBarController?.refresh()
    }

    func readClipboard() {
        guard ensureTextToSpeechAvailableForNewWork() else { return }
        do {
            try startTextToSpeechReadback(text: insertionService.clipboardText())
        } catch {
            showRecoverableMessage(error.localizedDescription)
        }
    }

    func previewTextToSpeechSavedVoice(text: String) {
        guard ensureTextToSpeechAvailableForNewWork() else { return }
        let configuration = textToSpeechSettings.activeVoiceConfiguration
        do { try startTextToSpeechReadback(text: text, configuration: configuration) }
        catch { showRecoverableMessage(error.localizedDescription) }
    }

    func previewTextToSpeechDraft() {
        let sample = "The cedar comet crossed a quiet yellow harbour."
        guard ensureTextToSpeechAvailableForNewWork() else { return }
        do { try startTextToSpeechReadback(text: sample, configuration: textToSpeechDraft) }
        catch { showRecoverableMessage(error.localizedDescription) }
    }

    func pauseOrResumeTextToSpeech() {
        guard case .speaking(let paused) = textToSpeechState else { return }
        if paused { textToSpeechPlayback.resume() }
        else { textToSpeechPlayback.pause() }
        transitionTextToSpeech(to: .speaking(paused: !paused))
    }

    func cancelTextToSpeech() {
        if selectedTextCaptureTask != nil {
            cancelSelectedTextCapture()
            return
        }
        guard textToSpeechState.isActive else { return }
        let operationID = textToSpeechOperationID
        transitionTextToSpeech(to: .canceling)
        textToSpeechPlayback.stop()
        if let jobID = activeTextToSpeechJobID,
           let endpoint = textToSpeechServer.endpoint,
           let token = textToSpeechServer.token {
            Task { [weak self] in
                guard let self else { return }
                await self.textToSpeechClient.cancel(jobID: jobID, endpoint: endpoint, token: token)
                guard self.textToSpeechOperationID == operationID else { return }
                self.textToSpeechTask?.cancel()
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self,
                      self.textToSpeechOperationID == operationID,
                      self.textToSpeechState == .canceling else { return }
                self.textToSpeechTask?.cancel()
                self.textToSpeechServer.forceStop()
            }
        } else {
            textToSpeechTask?.cancel()
            textToSpeechServer.forceStop()
        }
    }

    func generateSpeechAudio(text: String, format: TextToSpeechFormat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ensureTextToSpeechAvailableForNewWork() else { return }
        let configuration = textToSpeechSettings.activeVoiceConfiguration
        let panel = NSSavePanel()
        panel.title = "Save Generated Speech"
        panel.nameFieldStringValue = (try? SpeechAudioDocument.suggestedURL(text: trimmed, format: format).lastPathComponent)
            ?? "Generated Speech.wav"
        panel.directoryURL = try? SpeechAudioDocument.directory()
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        startSpeechAudioGeneration(
            text: trimmed,
            configuration: configuration,
            format: format,
            destination: destination
        )
    }

    func openGeneratedSpeechFolder() {
        guard let directory = try? SpeechAudioDocument.directory() else { return }
        NSWorkspace.shared.open(directory)
    }

    func openSavedVoicesFolder() {
        let modelsDirectory = textToSpeechModelsDirectory()
        let directory = modelsDirectory.deletingLastPathComponent().appendingPathComponent("SavedVoices", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
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
            guard AppConfiguration.isGGUF(url) else {
                dictationEngineStatus = .error("The selected file is not a valid GGUF speech model.")
                transition(to: .configurationRequired(.modelMissing))
                return
            }
            // Import is an explicit installed-model selection. It shares the
            // picker lifecycle: remember it, replace a loaded engine when
            // Dictation is enabled, and remain unloaded when it is disabled.
            selectInstalledSpeechModel(.init(url: url, variant: SpeechModelVariant.identify(url)))
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
        configuration.persist(to: modelCatalogConfiguration.defaults)
        menuBarController?.refresh()

        guard serverManager.isRunning, realtimeConnected else { return }
        realtimeClient.updateLanguage(
            language.rawValue,
            automaticPunctuation: settings.automaticPunctuation
        )
    }

    func refreshConfigurationAndStart() {
        guard localFeatureSettings.dictation.enabled else { return }
        guard isInstalledInApplications || isTextToSpeechPreview else {
            transition(to: .installationRequired)
            showSetup()
            return
        }
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

    func showModelsAndStartup() {
        if setupWindowController == nil { setupWindowController = SetupWindowController(coordinator: self) }
        refreshPermissions()
        setupWindowController?.showModelsAndStartup()
    }

    func showShortcutSettings() {
        if setupWindowController == nil { setupWindowController = SetupWindowController(coordinator: self) }
        refreshPermissions()
        setupWindowController?.showShortcuts()
    }

    func showDictationPermissions() {
        if setupWindowController == nil { setupWindowController = SetupWindowController(coordinator: self) }
        refreshPermissions()
        setupWindowController?.showDictationPermissions()
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
    func openMicrophoneSettings() {
        if !permissionManager.openMicrophoneSettings() { showRecoverableMessage("System Settings could not open Microphone privacy settings.") }
    }
    func openAccessibilitySettings() {
        if !permissionManager.openAccessibilitySettings() { showRecoverableMessage("System Settings could not open Accessibility privacy settings.") }
    }
    func openSystemAudioSettings() {
        if !permissionManager.openSystemAudioSettings() { showRecoverableMessage("System Settings could not open Screen & System Audio Recording settings.") }
    }

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
        cancelSelectedTextCapture()
        cancelTextToSpeech()
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
            await self.textToSpeechServer.stop()
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
        cancelSelectedTextCapture()
        cancelTextToSpeech()
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
            await self.textToSpeechServer.stop()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate() {
        transcriptionActivity.setActive(false)
        speechEngineTask?.cancel()
        wakeRecoveryTask?.cancel()
        terminationDeadlineTask?.cancel()
        mediaFileTranscriptionTask?.cancel()
        mediaFileProgressTask?.cancel()
        textToSpeechTask?.cancel()
        textToSpeechPlayback.stop()
        permissionMonitorTask?.cancel()
        permissionRequestTask?.cancel()
        targetCaptureTask?.cancel()
        cancelSelectedTextCapture()
        dismissTransientMessage()
        finalizationDelayTask?.cancel()
        conversationTask?.cancel()
        cancelModelDownload()
        audioCapture.cancel()
        conversationSession?.closeForApplicationTermination()
        hotkeyController.stop()
        realtimeClient.disconnect()
        textToSpeechServer.forceStop()
        stopPowerMonitoring()
        serverManager.forceStop()
    }

    private func prepareRealtimeConnection() {
        guard localFeatureSettings.dictation.enabled, let url = serverManager.realtimeURL else { return }
        permissionStatus = permissionManager.status
        expectedRealtimeConnectionID = realtimeClient.connect(
            to: url,
            automaticPunctuation: settings.automaticPunctuation,
            languageCode: configuration.recognitionLanguage.rawValue
        )
    }

    nonisolated static func acceptsRealtimeEvent(
        connectionID: UUID?,
        expectedConnectionID: UUID?,
        dictationEnabled: Bool,
        isUnloading: Bool
    ) -> Bool {
        dictationEnabled && !isUnloading && connectionID != nil && connectionID == expectedConnectionID
    }

    private func handleRealtimeConnection(_ connected: Bool, connectionID: UUID?) {
        // Disconnect is part of an explicit unload. A late connection callback
        // must not turn the old engine back into a ready/error state.
        guard Self.acceptsRealtimeEvent(
            connectionID: connectionID,
            expectedConnectionID: expectedRealtimeConnectionID,
            dictationEnabled: localFeatureSettings.dictation.enabled,
            isUnloading: dictationUnloading
        ) else { return }
        realtimeConnected = connected
        speechEngineReady = connected && serverManager.isRunning
        if connected { dictationEngineStatus = .ready }
        guard !isQuitting, !isPowerTransitioning else { return }
        if connected {
            activateHotkeysIfPossible()
            resumeDictationAfterLoad()
        } else if serverManager.isRunning, localFeatureSettings.dictation.enabled {
            pendingDictationAfterLoad = nil
            dictationEngineStatus = .error("The live transcription connection was interrupted.")
            transition(to: .serverUnavailable("The live transcription connection was interrupted."))
        }
    }

    private func activateHotkeysIfPossible() {
        updatePermissionStatus()
        guard localFeatureSettings.dictation.enabled || localFeatureSettings.readAloud.enabled else {
            hotkeyController.stop()
            globalShortcutOperational = false
            return
        }
        guard permissionManager.accessibilityGranted else {
            if hotkeyController.isRunning { hotkeyController.stop() }
            globalShortcutOperational = false
            updatePermissionStatus()
            if serverManager.isRunning, realtimeConnected { transition(to: .permissionRequired) }
            return
        }
        hotkeyController.bindings = settings.bindings
        if hotkeyController.isRunning {
            globalShortcutOperational = true
            updatePermissionStatus()
        } else if hotkeyController.start() {
            globalShortcutOperational = true
            updatePermissionStatus()
        } else {
            globalShortcutOperational = false
            updatePermissionStatus()
            if serverManager.isRunning, realtimeConnected { transition(to: .permissionRequired) }
            return
        }
        logger.info(
            "GLOBAL_HOTKEY status raw_ax_trusted=\(self.permissionManager.accessibilityGranted, privacy: .public) tap_running=\(self.hotkeyController.isRunning, privacy: .public)"
        )
        refreshHotkeyGates()
        if localFeatureSettings.dictation.enabled, serverManager.isRunning, realtimeConnected {
            if permissionStatus.microphone {
                switch state {
                case .permissionRequired, .starting, .loadingModel:
                    transition(to: .ready)
                default:
                    break
                }
            } else if state == .ready {
                transition(to: .permissionRequired)
            }
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
                let previousTextSelectionAccessibility = self.textSelectionAccessibilityGranted
                self.updatePermissionStatus()
                if self.permissionStatus != previous
                    || self.textSelectionAccessibilityGranted != previousTextSelectionAccessibility
                    || ((self.speechEngineReady || self.textSelectionAccessibilityGranted)
                        && !self.globalShortcutOperational) {
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
        restoreDictationAfterWake = localFeatureSettings.dictation.enabled && dictationEngineStatus == .ready
        restoreReadAloudAfterWake = localFeatureSettings.readAloud.enabled && readAloudEngineStatus == .ready
        wakeRecoveryTask?.cancel()
        speechEngineTask?.cancel()
        mediaFileTranscriptionTask?.cancel()
        mediaFileProgressTask?.cancel()
        cancelSelectedTextCapture()
        cancelTextToSpeech()
        Task { [textToSpeechServer] in await textToSpeechServer.stop() }
        realtimeClient.disconnect()
        realtimeConnected = false
        speechEngineReady = false
        if state == .recordingConversation {
            stopConversationTranscript()
        } else {
            cancelDictation()
        }
        transition(to: .ready)
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
            self.isPowerTransitioning = false
            if self.restoreDictationAfterWake, self.localFeatureSettings.dictation.enabled {
                self.scheduleSpeechEngineStart(restart: true)
            } else {
                self.dictationEngineStatus = self.localFeatureSettings.dictation.enabled ? .notLoaded : .disabled
                self.transition(to: .ready)
            }
            if self.restoreReadAloudAfterWake, self.localFeatureSettings.readAloud.enabled {
                self.loadReadAloudEngine()
            }
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
        switch permission {
        case .microphone:
            guard !permissionStatus.microphone else { return }
            let granted = await permissionManager.requestMicrophone()
            // TCC only shows its prompt once. If it was denied, take the user
            // straight to the precise privacy pane instead of appearing inert.
            if !granted, !permissionManager.openMicrophoneSettings() {
                showRecoverableMessage("System Settings could not open Microphone privacy settings.")
            }
        case .accessibility:
            // An event tap can be running even when the Accessibility API is not
            // trusted. Reading selected text requires the latter permission.
            guard !permissionManager.accessibilityGranted else { return }
            let granted = permissionManager.requestAccessibility()
            if !granted, !permissionManager.openAccessibilitySettings() {
                showRecoverableMessage("System Settings could not open Accessibility privacy settings.")
            }
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
        microphonePermissionState = permissionManager.microphoneState
        let rawTextSelectionAccessibility = permissionManager.accessibilityGranted
        if rawTextSelectionAccessibility != textSelectionAccessibilityGranted {
            textSelectionAccessibilityGranted = rawTextSelectionAccessibility
            menuBarController?.refresh()
        }
        let updated = permissionManager.status
        if updated != permissionStatus { permissionStatus = updated }
        // A live capture is the proof that conversation transcripts can start.
        // For display, the System Settings decision (ScreenCapture preflight)
        // also counts, so an approved permission shows as allowed before its
        // first use.
        let updatedSystemAudio = systemAudioOperational || permissionManager.systemAudioGranted
        if updatedSystemAudio != systemAudioPermissionGranted {
            systemAudioPermissionGranted = updatedSystemAudio
            menuBarController?.refresh()
        }
        if !systemAudioOperational, systemAudioPermissionState == .verifiedCurrentCapture {
            systemAudioPermissionState = .unknown
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
              !textToSpeechState.isActive,
              selectedTextCaptureTask == nil,
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
                self.systemAudioPermissionState = .verifiedCurrentCapture
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
                self.systemAudioPermissionState = .unknown
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
                self.systemAudioOperational = false
                self.systemAudioPermissionGranted = false
                self.systemAudioPermissionState = .unknown
                self.overlayController.hide()
                let shouldRestart = self.conversationRestartQueued
                self.conversationRestartQueued = false
                self.transition(to: .ready)
                self.menuBarController?.showConversationSaved(at: fileURL)
                self.transcriptNotifier.notifyConversationSaved(at: fileURL)
                if shouldRestart { self.startConversationTranscript() }
            } catch {
                if self.conversationSession === session { self.conversationSession = nil }
                self.conversationStartedAt = nil
                self.conversationTask = nil
                self.systemAudioOperational = false
                self.systemAudioPermissionGranted = false
                self.systemAudioPermissionState = .unknown
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
            guard localFeatureSettings.dictation.enabled else { return }
            if loadDictationEngineOnDemand() {
                showRecoverableMessage("Loading the speech model… keep holding to dictate as soon as it is ready.")
            } else if state == .ready { scheduleDictationStart(mode: .pushToTalk) }
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
        case .readSelectedText:
            readSelectedText()
        case .pauseOrResumeTextToSpeech:
            pauseOrResumeTextToSpeech()
        case .cancel:
            pendingDictationAfterLoad = nil
            if textToSpeechState.isActive {
                cancelTextToSpeech()
            } else if selectedTextCaptureTask != nil {
                cancelSelectedTextCapture()
            } else if transientMessageID != nil {
                dismissTransientMessage()
            } else if targetCaptureTask != nil {
                targetCaptureTask?.cancel()
                targetCaptureTask = nil
            } else {
                cancelDictation()
            }
        }
    }

    private func loadTextToSpeechVoicesIfNeeded() {
        guard localFeatureSettings.readAloud.enabled, textToSpeechVoices.isEmpty,
              !textToSpeechState.isActive, selectedTextCaptureTask == nil else { return }
        refreshTextToSpeechInstallStatus()
        guard textToSpeechModelInstallStatus.runtimeInstalled,
              textToSpeechModelInstallStatus.customVoiceInstalled else {
            readAloudEngineStatus = .notLoaded
            transitionTextToSpeech(to: .unavailable("The selected voice model needs setup. Open Models & Startup to install its runtime and preset voices."))
            return
        }
        let operationID = UUID()
        textToSpeechOperationID = operationID
        textToSpeechTask?.cancel()
        readAloudEngineStatus = .loading
        transitionTextToSpeech(to: .starting)
        textToSpeechTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.prepareTextToSpeechRuntime(
                    operationID: operationID,
                    model: self.localFeatureSettings.readAloud.model,
                    voiceID: self.textToSpeechSettings.activeVoiceConfiguration.voiceID
                )
                self.readAloudEngineStatus = .ready
                self.finishTextToSpeechOperation(operationID, state: .ready)
            } catch is CancellationError {
                self.readAloudEngineStatus = self.localFeatureSettings.readAloud.enabled ? .notLoaded : .disabled
                self.finishTextToSpeechOperation(operationID, state: .idle)
            } catch {
                let failedState: TextToSpeechState
                if let textToSpeechError = error as? TextToSpeechError,
                   case .runtimeMissing = textToSpeechError {
                    failedState = .unavailable(error.localizedDescription)
                } else {
                    failedState = .error(error.localizedDescription)
                }
                self.readAloudEngineStatus = .error(error.localizedDescription)
                self.finishTextToSpeechOperation(operationID, state: failedState)
            }
        }
    }

    private func ensureTextToSpeechAvailableForNewWork() -> Bool {
        guard localFeatureSettings.readAloud.enabled else { return false }
        return canUseTextToSpeech
    }

    private static func selectionCaptureOutcome(_ error: Error) -> String {
        guard let error = error as? SelectedTextError else { return "unknown" }
        switch error {
        case .accessibilityPermissionRequired: return "accessibility_permission_required"
        case .noStandardSelection: return "no_standard_selection"
        case .secureField: return "secure_field"
        case .emptySelection: return "empty_selection"
        case .captureInProgress: return "capture_in_progress"
        }
    }

    private func startTextToSpeechReadback(
        text: String,
        configuration requestedConfiguration: TextToSpeechVoiceConfiguration? = nil
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SelectedTextError.emptySelection }
        // Hold one immutable configuration for the whole job. Runtime warmup is
        // asynchronous, so reading settings inside its task would let later edits
        // change an already-started readback.
        let configuration = requestedConfiguration ?? textToSpeechSettings.activeVoiceConfiguration
        let operationID = UUID()
        let jobID = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictation-TTS-\(jobID)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        textToSpeechOperationID = operationID
        activeTextToSpeechJobID = jobID
        activeTextToSpeechTemporaryDirectory = temporaryDirectory
        textToSpeechTask?.cancel()
        transitionTextToSpeech(to: .starting)
        textToSpeechTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selectedModel = self.localFeatureSettings.readAloud.model
                let (endpoint, token) = try await self.prepareTextToSpeechRuntime(operationID: operationID, model: selectedModel, voiceID: configuration.voiceID)
                let request = TextToSpeechRequest(
                    jobID: jobID,
                    text: trimmed,
                    textPath: nil,
                    voiceID: configuration.voiceID,
                    modelID: selectedModel,
                    voicePrompt: self.voicePrompt(for: configuration),
                    outputPath: temporaryDirectory.path,
                    format: .wav,
                    stream: true,
                    chunkMaxCharacters: 500,
                    pronunciationOverrides: pronunciationOverrides(for: configuration)
                )
                let playbackGeneration = self.textToSpeechPlayback.begin()
                try await self.textToSpeechClient.stream(request, endpoint: endpoint, token: token) { [weak self] event in
                    guard let self, self.textToSpeechOperationID == operationID else { throw CancellationError() }
                    guard event.type == "audio_chunk",
                          let path = event.path,
                          let eventJobID = event.jobID,
                          let index = event.index else { return }
                    guard eventJobID == jobID,
                          self.isSafeTextToSpeechChunk(path: path, in: temporaryDirectory) else {
                        throw TextToSpeechError.invalidResponse
                    }
                    let chunkURL = URL(fileURLWithPath: path)
                    self.transitionTextToSpeech(to: .speaking(paused: self.textToSpeechPlayback.isPaused))
                    try self.textToSpeechPlayback.enqueue(url: chunkURL, generation: playbackGeneration) { [weak self] in
                        guard let self, self.textToSpeechOperationID == operationID else { return }
                        Task { [weak self] in
                            guard let self, self.textToSpeechOperationID == operationID else { return }
                            await self.textToSpeechClient.acknowledge(
                                jobID: eventJobID,
                                index: index,
                                endpoint: endpoint,
                                token: token
                            )
                            try? FileManager.default.removeItem(at: chunkURL)
                        }
                    }
                }
                self.textToSpeechPlayback.producerDidComplete(generation: playbackGeneration)
                try await self.textToSpeechPlayback.waitUntilDrained(generation: playbackGeneration)
                try? FileManager.default.removeItem(at: temporaryDirectory)
                self.finishTextToSpeechOperation(operationID, state: .ready)
            } catch is CancellationError {
                await self.cancelActiveTextToSpeechWorker(jobID: jobID)
                try? FileManager.default.removeItem(at: temporaryDirectory)
                self.finishTextToSpeechOperation(operationID, state: .ready)
            } catch {
                self.textToSpeechPlayback.stop()
                await self.cancelActiveTextToSpeechWorker(jobID: jobID)
                try? FileManager.default.removeItem(at: temporaryDirectory)
                self.finishTextToSpeechOperation(operationID, state: .error(error.localizedDescription))
            }
        }
    }

    private func startSpeechAudioGeneration(
        text: String,
        configuration: TextToSpeechVoiceConfiguration,
        format: TextToSpeechFormat,
        destination: URL
    ) {
        let operationID = UUID()
        let jobID = UUID().uuidString
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictation-TTS-\(jobID)", isDirectory: true)
        let stagingTextURL = stagingDirectory.appendingPathComponent("input.txt")
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try text.write(to: stagingTextURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingTextURL.path)
        } catch {
            showRecoverableMessage("The text could not be prepared for local speech generation: \(error.localizedDescription)")
            return
        }
        textToSpeechOperationID = operationID
        activeTextToSpeechJobID = jobID
        textToSpeechProgress = nil
        textToSpeechProgressDetail = ""
        transitionTextToSpeech(to: .starting)
        textToSpeechTask = Task { [weak self] in
            guard let self else { return }
            var workerStagingURL: URL?
            do {
                let selectedModel = self.localFeatureSettings.readAloud.model
                let (endpoint, token) = try await self.prepareTextToSpeechRuntime(operationID: operationID, model: selectedModel, voiceID: configuration.voiceID)
                self.transitionTextToSpeech(to: .generating)
                let request = TextToSpeechRequest(
                    jobID: jobID,
                    text: nil,
                    textPath: stagingTextURL.path,
                    voiceID: configuration.voiceID,
                    modelID: selectedModel,
                    voicePrompt: self.voicePrompt(for: configuration),
                    outputPath: destination.path,
                    format: format,
                    stream: false,
                    chunkMaxCharacters: 500,
                    pronunciationOverrides: pronunciationOverrides(for: configuration)
                )
                var completed = false
                try await self.textToSpeechClient.stream(request, endpoint: endpoint, token: token) { [weak self] event in
                    guard let self, self.textToSpeechOperationID == operationID else { throw CancellationError() }
                    if event.type == "started", let stagingPath = event.stagingPath {
                        guard let safeStagingURL = TextToSpeechExportStaging.validatedURL(
                            path: stagingPath,
                            destination: destination,
                            jobID: jobID
                        ) else { throw TextToSpeechError.invalidResponse }
                        workerStagingURL = safeStagingURL
                    }
                    if event.type == "error" || event.type == "cancelled" {
                        throw TextToSpeechError.server(event.message ?? "Audio generation did not complete.")
                    }
                    if event.type == "progress", let fraction = event.fraction {
                        self.textToSpeechProgress = min(1, max(0, fraction))
                    }
                    if event.type == "progress" {
                        if let frames = event.frames, let rate = event.sampleRate, rate > 0 {
                            self.textToSpeechProgressDetail = Self.formattedAudioDuration(Double(frames) / Double(rate)) + " of audio created"
                        } else {
                            self.textToSpeechProgressDetail = "Generating…"
                        }
                    }
                    if event.type == "completed" { completed = true }
                }
                guard completed else { throw TextToSpeechError.invalidResponse }
                guard self.textToSpeechOperationID == operationID else { return }
                self.lastGeneratedSpeechURL = destination
                try? FileManager.default.removeItem(at: stagingDirectory)
                self.finishTextToSpeechOperation(operationID, state: .ready)
                self.showSetup()
                self.setupWindowController?.showReadAloudSavedSpeech(at: destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                await self.cancelActiveTextToSpeechWorker(jobID: jobID)
                if let workerStagingURL { try? FileManager.default.removeItem(at: workerStagingURL) }
                try? FileManager.default.removeItem(at: stagingDirectory)
                self.finishTextToSpeechOperation(operationID, state: .ready)
            } catch {
                await self.cancelActiveTextToSpeechWorker(jobID: jobID)
                if let workerStagingURL { try? FileManager.default.removeItem(at: workerStagingURL) }
                try? FileManager.default.removeItem(at: stagingDirectory)
                self.finishTextToSpeechOperation(operationID, state: .error(error.localizedDescription))
            }
        }
    }

    private func prepareTextToSpeechRuntime(
        operationID: UUID,
        model: TextToSpeechModelChoice,
        voiceID: String
    ) async throws -> (URL, String) {
        guard textToSpeechOperationID == operationID else { throw CancellationError() }
        transitionTextToSpeech(to: .starting)
        try await textToSpeechServer.start(modelID: model)
        guard textToSpeechOperationID == operationID,
              let endpoint = textToSpeechServer.endpoint,
              let token = textToSpeechServer.token else { throw CancellationError() }
        let voices = try await textToSpeechClient.voices(endpoint: endpoint, token: token)
        guard !voices.isEmpty else { throw TextToSpeechError.server("No local preset voices are available.") }
        // `/voices` is a catalog query. Preloading is deliberately explicit so
        // status reads and settings presentation never allocate model memory.
        try await textToSpeechClient.preload(
            modelID: model,
            voiceID: voiceID,
            endpoint: endpoint,
            token: token
        )
        textToSpeechVoices = voices
        return (endpoint, token)
    }

    private func voicePrompt(for configuration: TextToSpeechVoiceConfiguration) -> String? {
        guard configuration.voiceID != "designed-narrator" else { return nil }
        let trimmed = configuration.voicePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isSafeTextToSpeechChunk(path: String, in directory: URL) -> Bool {
        TextToSpeechChunkPath.isSafe(path: path, in: directory)
    }

    private func pronunciationOverrides(for configuration: TextToSpeechVoiceConfiguration) -> [TextToSpeechPronunciationOverride] {
        configuration.pronunciationOverridesText
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .prefix(200)
            .compactMap { line in
                let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
                return TextToSpeechPronunciationOverride(from: pair[0], to: pair[1])
            }
    }

    private static func formattedAudioDuration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return whole >= 60 ? "\(whole / 60)m \(whole % 60)s" : "\(whole)s"
    }

    private func finishTextToSpeechOperation(_ operationID: UUID, state: TextToSpeechState) {
        guard textToSpeechOperationID == operationID else { return }
        textToSpeechTask = nil
        textToSpeechOperationID = nil
        activeTextToSpeechJobID = nil
        activeTextToSpeechTemporaryDirectory = nil
        textToSpeechProgress = nil
        textToSpeechProgressDetail = ""
        if state == .ready, textToSpeechServer.isRunning {
            readAloudEngineStatus = .ready
        }
        transitionTextToSpeech(to: state)
    }

    private func cancelActiveTextToSpeechWorker(jobID: String) async {
        if let endpoint = textToSpeechServer.endpoint, let token = textToSpeechServer.token {
            await textToSpeechClient.cancel(jobID: jobID, endpoint: endpoint, token: token)
        }
        await textToSpeechServer.stop()
        readAloudEngineStatus = localFeatureSettings.readAloud.enabled ? .notLoaded : .disabled
    }

    private func clearSelectedTextCapture(id: UUID) {
        guard selectedTextCaptureID == id else { return }
        selectedTextCaptureTask = nil
        selectedTextCaptureID = nil
        refreshTextToSpeechHotkeys()
        menuBarController?.refresh()
    }

    private func cancelSelectedTextCapture() {
        selectedTextCaptureTask?.cancel()
        selectedTextCaptureTask = nil
        selectedTextCaptureID = nil
        refreshTextToSpeechHotkeys()
        menuBarController?.refresh()
    }

    private func removeStaleTextToSpeechTemporaryFiles() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for item in contents where item.lastPathComponent.hasPrefix("LocalDictation-TTS-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func transitionTextToSpeech(to newState: TextToSpeechState) {
        guard textToSpeechState != newState else { return }
        textToSpeechState = newState
        refreshHotkeyGates()
        menuBarController?.refresh()
        rescheduleIdleUnload()
    }

    private func refreshHotkeyGates() {
        let canLoadDictationOnDemand: Bool
        switch dictationEngineStatus {
        case .notLoaded, .error: canLoadDictationOnDemand = true
        default: canLoadDictationOnDemand = false
        }
        let dictationReadyOrLoadable = (serverManager.isRunning && realtimeConnected) || canLoadDictationOnDemand
        hotkeyController.isDictationShortcutEnabled = globalShortcutOperational
            && localFeatureSettings.dictation.enabled
            && dictationReadyOrLoadable
            && permissionStatus.microphone
            && state == .ready
            && !isTextToSpeechOperationActive
        let readyOrLoadableForToggle = state == .ready && permissionStatus.microphone
            && ((serverManager.isRunning && realtimeConnected) || canLoadDictationOnDemand)
        hotkeyController.isConversationShortcutEnabled = localFeatureSettings.dictation.enabled
            && (readyOrLoadableForToggle
                || state == .recordingConversation || state == .savingConversation)
        hotkeyController.isLongDictationShortcutEnabled = localFeatureSettings.dictation.enabled
            && !isTextToSpeechOperationActive
            && (readyOrLoadableForToggle
                || state == .recording(.handsFree) || state == .recording(.pushToTalk))
        refreshTextToSpeechHotkeys()
    }

    private func refreshTextToSpeechHotkeys() {
        hotkeyController.isTextToSpeechActive = textToSpeechState.isActive
        hotkeyController.isTextToSpeechSelectionCaptureActive = selectedTextCaptureTask != nil
        hotkeyController.isTextToSpeechReadShortcutEnabled = TextToSpeechShortcutGate.readEnabled(
            settingsEnabled: textToSpeechSettings.shortcutsEnabled,
            canStart: canUseTextToSpeech,
            isActive: textToSpeechState.isActive
        )
        if case .speaking = textToSpeechState {
            hotkeyController.isTextToSpeechPauseShortcutEnabled = TextToSpeechShortcutGate.pauseEnabled(
                settingsEnabled: textToSpeechSettings.shortcutsEnabled,
                isSpeaking: true
            )
        } else {
            hotkeyController.isTextToSpeechPauseShortcutEnabled = false
        }
    }

    private func scheduleDictationStart(mode: DictationMode) {
        guard localFeatureSettings.dictation.enabled, dictationEngineStatus == .ready,
              targetCaptureTask == nil, selectedTextCaptureTask == nil, state == .ready, !textToSpeechState.isActive else { return }
        targetCaptureTask = Task { [weak self] in
            guard let self else { return }
            await self.beginDictation(mode: mode)
            self.targetCaptureTask = nil
        }
    }

    private func beginDictation(mode: DictationMode) async {
        guard localFeatureSettings.dictation.enabled, dictationEngineStatus == .ready,
              state == .ready, realtimeConnected, !textToSpeechState.isActive, selectedTextCaptureTask == nil else { return }
        dismissTransientMessage()
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
        dictationHistory.record(rawTranscript: rawTranscript, text: processed.text)
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

    private func handleRealtimeError(_ error: Error, connectionID: UUID? = nil) {
        guard !isQuitting,
              Self.acceptsRealtimeEvent(
                connectionID: connectionID,
                expectedConnectionID: expectedRealtimeConnectionID,
                dictationEnabled: localFeatureSettings.dictation.enabled,
                isUnloading: dictationUnloading
              ) else { return }
        finalizationDelayTask?.cancel()
        finalizationDelayTask = nil
        audioCapture.cancel()
        insertionTarget = nil
        overlayController.showMessage(error.localizedDescription)
        transition(to: .error(error.localizedDescription))
    }

    private func showRecoverableMessage(_ message: String) {
        let messageID = overlayController.showTransientMessage(message) { [weak self] messageID in
            guard let self, self.transientMessageID == messageID else { return }
            self.transientMessageID = nil
            self.hotkeyController.isTransientMessageVisible = false
        }
        transientMessageID = messageID
        hotkeyController.isTransientMessageVisible = true
    }

    private func dismissTransientMessage() {
        guard let messageID = transientMessageID else { return }
        transientMessageID = nil
        hotkeyController.isTransientMessageVisible = false
        overlayController.hideMessage(messageID)
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
        // The selected configuration is the one the next explicit Load must
        // use. Do not let an earlier launch task revive the previous model.
        speechEngineTask?.cancel()
        speechEngineTask = nil
        speechEngineOperationID = nil
        configuration = AppConfiguration(
            engineURL: engineURL,
            modelURL: modelURL,
            recognitionLanguage: recognitionLanguage
        )
        configuration.persist(to: modelCatalogConfiguration.defaults)
        if let issue = configuration.validate() {
            dictationEngineStatus = .error(issue.message)
            transition(to: .configurationRequired(issue))
        } else {
            // Choosing or downloading a model records the selection only. A
            // model is loaded by an explicit Load action (or its startup flag).
            if serverManager.isRunning { unloadDictationEngine() }
            dictationEngineStatus = localFeatureSettings.dictation.enabled ? .notLoaded : .disabled
            transition(to: .ready)
        }
    }

    private func scheduleSpeechEngineStart(restart: Bool) {
        guard localFeatureSettings.dictation.enabled, !isQuitting else {
            dictationEngineStatus = .disabled
            return
        }
        let previousTask = speechEngineTask
        previousTask?.cancel()
        let operationID = UUID()
        speechEngineOperationID = operationID
        dictationEngineStatus = .loading
        speechEngineTask = Task { [weak self] in
            if let previousTask { await previousTask.value }
            guard !Task.isCancelled, let self, !self.isQuitting,
                  self.speechEngineOperationID == operationID else { return }

            if let issue = self.configuration.validate() {
                self.isPowerTransitioning = false
                self.dictationEngineStatus = .error(issue.message)
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
                self.dictationEngineStatus = .error(error.localizedDescription)
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
        AppConfiguration.rememberSpeechModel(fileURL, defaults: modelCatalogConfiguration.defaults)
        refreshInstalledSpeechModels()
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
        // A download adds an installed choice. Preserve a valid active model;
        // the first valid download becomes active only when no model is usable.
        guard configuration.validateModel() != nil else { return }
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
        alert.addButton(withTitle: "Download")
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
        refreshHotkeyGates()
        menuBarController?.refresh()
        rescheduleIdleUnload()
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
