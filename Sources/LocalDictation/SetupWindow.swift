import AppKit
import SwiftUI

@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    init(coordinator: AppCoordinator) {
        let hosting = NSHostingController(rootView: SetupView(coordinator: coordinator))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Local Dictation Setup"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 800))
        window.minSize = NSSize(width: 650, height: 700)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndActivate() {
        // Menu-bar apps normally stay out of the Dock and Command-Tab. While
        // setup is open, behave like a normal app so the window remains easy
        // to recover after macOS brings System Settings to the front.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct SetupView: View {
    @ObservedObject var coordinator: AppCoordinator

    private var engineReady: Bool { coordinator.configuration.validateEngine() == nil }
    private var modelReady: Bool { coordinator.configuration.validateModel() == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Text("The app runs speech recognition locally. NVIDIA model weights are not included and are never downloaded without your action.")
                    .fixedSize(horizontal: false, vertical: true)

                if !coordinator.isInstalledInApplications {
                    GroupBox("Install before granting permissions") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                "This copy is running from a temporary location. macOS privacy approvals will not reliably follow it.",
                                systemImage: "externaldrive.badge.exclamationmark"
                            )
                            .foregroundStyle(.orange)
                            Text("Install and relaunch first. The model remains a separate download and is not copied into the app.")
                                .font(.callout)
                            Text(Bundle.main.bundleURL.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let installationError = coordinator.installationError {
                                Text(installationError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Button("Install in Applications and Relaunch", action: coordinator.installInApplications)
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(6)
                    }
                }

                if coordinator.isInstalledInApplications && !modelReady {
                    GroupBox("Choose your speech model") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Choose once and Local Dictation will download, verify, select, and start the model for you. If you already chose a valid model file, that saved location is used instead.")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(alignment: .top, spacing: 12) {
                                firstRunModelChoice(
                                    title: "English",
                                    detail: "Fast, accurate English dictation · about 700 MB",
                                    badge: "Recommended",
                                    action: coordinator.downloadEnglishModel
                                )
                                firstRunModelChoice(
                                    title: "Multilingual",
                                    detail: "Spanish, English, and many more languages · about 742 MB",
                                    badge: "Multilingual",
                                    action: coordinator.downloadMultilingualModel
                                )
                            }

                            modelDownloadStatus

                            HStack {
                                Button("Use a Model Already on This Mac…", action: coordinator.chooseModel)
                                Spacer()
                                Text("Models are stored in Application Support, outside the app.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                    }
                    .disabled(!coordinator.canEditSpeechConfiguration)
                }

                GroupBox("Speech engine and model") {
                    VStack(spacing: 14) {
                        readinessRow(
                            ready: engineReady,
                            title: "Speech engine",
                            detail: coordinator.configuration.engineURL.path,
                            action: coordinator.chooseEngine
                        )
                        Divider()
                        readinessRow(
                            ready: modelReady,
                            title: coordinator.configuration.modelVariant.title,
                            detail: coordinator.configuration.modelURL.path,
                            action: coordinator.chooseModel
                        )
                        Divider()
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "character.bubble")
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Transcription language").font(.headline)
                                Text(languageDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if coordinator.configuration.modelVariant.supportsLanguageSelection {
                                Picker("Transcription language", selection: languageBinding) {
                                    ForEach(RecognitionLanguage.allCases) { language in
                                        Text(language.title).tag(language)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 235)
                            } else {
                                Label("English", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .frame(width: 235, alignment: .trailing)
                            }
                        }
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            statusIcon(coordinator.speechEngineReady)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Loaded speech model").font(.headline)
                                Text(coordinator.speechEngineReady
                                     ? "Warm and ready for immediate local transcription."
                                     : "The model loads independently of keyboard permissions.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .padding(6)
                }
                .disabled(!coordinator.canEditSpeechConfiguration)

                GroupBox("Permissions for system-wide dictation") {
                    VStack(alignment: .leading, spacing: 12) {
                        permissionRow(
                            granted: coordinator.permissionStatus.microphone,
                            title: "Microphone",
                            detail: "Captures speech only while dictation is active.",
                            requestEnabled: coordinator.permissionStatus.firstMissing == .microphone,
                            requestAction: coordinator.requestMicrophonePermission,
                            settingsAction: coordinator.openMicrophoneSettings
                        )
                        permissionRow(
                            granted: coordinator.permissionStatus.accessibility,
                            title: "Accessibility",
                            detail: "Recognizes the Fn shortcut and inserts final text in other apps.",
                            requestEnabled: coordinator.permissionStatus.firstMissing == .accessibility,
                            requestAction: coordinator.requestAccessibilityPermission,
                            settingsAction: coordinator.openAccessibilitySettings
                        )

                        HStack {
                            Button("Refresh Status", action: coordinator.refreshPermissions)
                            Spacer()
                            if coordinator.permissionStatus.allGranted {
                                if coordinator.globalShortcutOperational || !coordinator.speechEngineReady {
                                    Label("Quick Dictation Permissions Ready", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Label("Global shortcut unavailable", systemImage: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        if coordinator.isInstalledInApplications && !coordinator.permissionStatus.allGranted {
                            Button("Repair Stale Permission Registration…", action: coordinator.repairPermissionRegistration)
                                .font(.caption)
                        }
                        Text("Approve one row at a time. Input Monitoring is not required. Each green check reflects a working permission; Refresh Status rechecks immediately after you return from System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }
                .disabled(!coordinator.isInstalledInApplications)

                GroupBox("Conversation transcripts (optional)") {
                    VStack(alignment: .leading, spacing: 12) {
                        systemAudioRow
                        Text("Start Conversation Transcript from the menu-bar icon to transcribe your microphone as “You” and Mac output as “Speaker.” A timestamped text file is saved in Documents → Local Dictation Transcripts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Open Transcripts Folder", action: coordinator.openConversationTranscriptsFolder)
                        }
                    }
                    .padding(6)
                }
                .disabled(!coordinator.isInstalledInApplications)

                GroupBox("Transcribe an audio or video file") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Choose a media file, review its duration and estimated transcription time, then confirm. The warm local model uses its fast offline path and saves an easy-to-read text file automatically.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(MediaFileTranscriptionService.supportedFormatsDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if coordinator.state == .transcribingFile || coordinator.state == .inspectingMedia {
                            ProgressView(value: coordinator.mediaFileProgress, total: 1)
                            Text(coordinator.mediaFileStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            if coordinator.state == .transcribingFile || coordinator.state == .inspectingMedia {
                                Button("Cancel", action: coordinator.cancelMediaFileTranscription)
                            } else {
                                Button("Choose Audio or Video…", action: coordinator.chooseMediaFileForTranscription)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!coordinator.canTranscribeMediaFile)
                            }
                            Button("Open File Transcripts Folder", action: coordinator.openFileTranscriptsFolder)
                        }
                        Text("Saved automatically in Documents → Local Dictation Transcripts → File Transcripts. Temporary converted audio is deleted after processing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("How to dictate") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Place the cursor in any normal text field.")
                        Text("2. \(coordinator.settings.shortcut.title), speak, then release.")
                        Text("3. The final transcript is inserted at the original cursor. Press Esc to cancel.")
                        Text("Long microphone-only dictation: choose Start Long Dictation from the menu.")
                        Text("Conversation file: press \(ConversationShortcut.title) once to start and again to stop. The menu-bar timer shows when recording is active.")
                        Text("Existing media: choose Transcribe Audio or Video File from the menu or Settings.")
                    }
                    .font(.callout)
                    .padding(6)
                }

                GroupBox("Official model download and terms") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose one model. Local Dictation downloads it from NVIDIA, verifies it, stores it in Application Support, and selects it automatically.")
                            .font(.callout)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("English 0.6B Q8").font(.headline)
                            Text("Best choice when every speaker uses English. Approximately 700 MB.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Download and Use English", action: coordinator.downloadEnglishModel)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(
                                        coordinator.modelDownloadState.isDownloading
                                            || !coordinator.canEditSpeechConfiguration
                                    )
                                Button("Model Page", action: coordinator.openEnglishModelPage)
                                Button("License", action: coordinator.openEnglishModelLicense)
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text("Multilingual 0.6B Q8").font(.headline)
                                Text("Spanish + 30 other locales")
                                    .font(.caption.bold())
                                    .foregroundStyle(.blue)
                            }
                            Text("Use for Spanish, mixed-language use, or automatic language detection. Includes es-US and es-ES. Approximately 742 MB.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Download and Use Multilingual", action: coordinator.downloadMultilingualModel)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(
                                        coordinator.modelDownloadState.isDownloading
                                            || !coordinator.canEditSpeechConfiguration
                                    )
                                Button("Model Page", action: coordinator.openMultilingualModelPage)
                                Button("OpenMDW 1.1 License", action: coordinator.openMultilingualModelLicense)
                            }
                        }
                        Divider()
                        modelDownloadStatus
                        Divider()
                        HStack {
                            Button("Runtime Source", action: coordinator.openRuntimePage)
                        }
                        Text("The models use different licenses and are not bundled with the app. Review the terms for the model you choose.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                HStack {
                    Label(overallStatusText, systemImage: overallStatusSymbol)
                        .foregroundStyle(overallStatusColor)
                    Spacer()
                    if !coordinator.isInstalledInApplications {
                        Button("Install in Applications", action: coordinator.installInApplications)
                            .buttonStyle(.borderedProminent)
                    } else if coordinator.speechEngineReady {
                        Label("Engine Running", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Refresh and Start Engine", action: coordinator.refreshConfigurationAndStart)
                            .disabled(!engineReady || !modelReady || coordinator.state == .loadingModel)
                    }
                }

                Divider()
                HStack {
                    Text("Working title; public branding still requires trademark review.")
                    Spacer()
                    Button("Removal Instructions…", action: coordinator.showRemovalInstructions)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .frame(minWidth: 650, minHeight: 680)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Local Dictation").font(.title.bold())
                Text("Private speech-to-text in every Mac app").foregroundStyle(.secondary)
            }
        }
    }

    private var languageBinding: Binding<RecognitionLanguage> {
        Binding(
            get: { coordinator.configuration.recognitionLanguage },
            set: { language in coordinator.setRecognitionLanguage(language) }
        )
    }

    private var languageDetail: String {
        if coordinator.configuration.modelVariant == .english {
            return "This model supports English only."
        }
        if coordinator.configuration.recognitionLanguage == .automatic {
            return "The model detects the language for each pause-bounded utterance."
        }
        return "Sent to every quick-dictation and conversation recognition stream."
    }

    @ViewBuilder
    private var modelDownloadStatus: some View {
        switch coordinator.modelDownloadState {
        case .idle:
            VStack(alignment: .leading, spacing: 3) {
                Label("Downloads stay visible here", systemImage: "arrow.down.circle")
                    .font(.headline)
                Text("Save location: \(modelsDirectoryPath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .downloading(let specification, let receivedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Downloading \(specification.title)", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                    Spacer()
                    Text(downloadPercentage(received: receivedBytes, total: totalBytes))
                        .font(.caption.monospacedDigit())
                    Button("Cancel", action: coordinator.cancelModelDownload)
                }
                ProgressView(
                    value: Double(receivedBytes),
                    total: Double(max(totalBytes, 1))
                )
                Text("\(fileSize(receivedBytes)) of \(fileSize(totalBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Saving to: \(specification.destinationURL.path)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .completed(let specification, let fileURL):
            VStack(alignment: .leading, spacing: 6) {
                Label(completedDownloadTitle(specification, fileURL: fileURL), systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(fileURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Show Model in Finder", action: coordinator.revealDownloadedModel)
            }
        case .failed(let specification, let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("\(specification.title) download failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Try Again") {
                    if specification.variant == .multilingual {
                        coordinator.downloadMultilingualModel()
                    } else {
                        coordinator.downloadEnglishModel()
                    }
                }
            }
        }
    }

    private var modelsDirectoryPath: String {
        AppConfiguration.supportDirectory()
            .appendingPathComponent("Models", isDirectory: true)
            .path
    }

    private func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    private func downloadPercentage(received: Int64, total: Int64) -> String {
        guard total > 0 else { return "Starting…" }
        return "\(min(100, Int((Double(received) / Double(total)) * 100)))%"
    }

    private func completedDownloadTitle(
        _ specification: SpeechModelDownloadSpecification,
        fileURL: URL
    ) -> String {
        if coordinator.configuration.modelURL.standardizedFileURL == fileURL.standardizedFileURL {
            return "\(specification.title) downloaded, verified, and selected"
        }
        return "\(specification.title) downloaded and verified; it will be selected when transcription finishes"
    }

    private var overallStatusText: String {
        if coordinator.state == .ready {
            return "Ready to dictate"
        }
        if coordinator.speechEngineReady && coordinator.permissionStatus.allGranted && coordinator.globalShortcutOperational {
            return "Ready to dictate"
        }
        if coordinator.speechEngineReady && coordinator.permissionStatus.allGranted {
            return "Permissions granted · global shortcut unavailable"
        }
        if coordinator.speechEngineReady {
            return "Speech model ready · finish permissions"
        }
        return coordinator.state.label
    }

    private var overallStatusSymbol: String {
        if coordinator.state == .ready {
            return "checkmark.circle.fill"
        }
        if coordinator.speechEngineReady && coordinator.permissionStatus.allGranted && coordinator.globalShortcutOperational {
            return "checkmark.circle.fill"
        }
        if coordinator.speechEngineReady { return "exclamationmark.circle.fill" }
        return coordinator.state.symbolName
    }

    private var overallStatusColor: Color {
        if coordinator.state == .ready {
            return .green
        }
        if coordinator.speechEngineReady && coordinator.permissionStatus.allGranted && coordinator.globalShortcutOperational {
            return .green
        }
        if coordinator.speechEngineReady { return .orange }
        switch coordinator.state {
        case .serverUnavailable, .error: return .red
        case .installationRequired, .configurationRequired, .permissionRequired: return .orange
        default: return .secondary
        }
    }

    private func readinessRow(
        ready: Bool,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(ready)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Choose…", action: action)
        }
    }

    private func firstRunModelChoice(
        title: String,
        detail: String,
        badge: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(badge)
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Download and Set Up (title)", action: action)
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.modelDownloadState.isDownloading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func permissionRow(
        granted: Bool,
        title: String,
        detail: String,
        requestEnabled: Bool,
        requestAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            statusIcon(granted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Allow…", action: requestAction)
                    .disabled(coordinator.permissionRequestInProgress || !requestEnabled)
                Button("Settings…", action: settingsAction)
                    .buttonStyle(.link)
                    .disabled(!requestEnabled)
            }
        }
    }

    private var systemAudioRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: coordinator.systemAudioPermissionGranted
                  ? "checkmark.circle.fill"
                  : "info.circle")
                .foregroundStyle(coordinator.systemAudioPermissionGranted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("System Audio Recording").font(.headline)
                Text(coordinator.systemAudioPermissionGranted
                     ? "Verified for the current app session. No screen video is captured."
                     : "Checked when a Conversation Transcript starts. It never blocks Quick Dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings…", action: coordinator.openSystemAudioSettings)
                .buttonStyle(.link)
                .fixedSize()
        }
    }

    private func statusIcon(_ ready: Bool) -> some View {
        Image(systemName: ready ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ready ? .green : .secondary)
            .font(.title3)
    }
}
