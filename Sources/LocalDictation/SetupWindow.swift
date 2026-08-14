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
                            title: "English streaming model",
                            detail: coordinator.configuration.modelURL.path,
                            action: coordinator.chooseModel
                        )
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

                GroupBox("How to dictate") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Place the cursor in any normal text field.")
                        Text("2. \(coordinator.settings.shortcut.title), speak, then release.")
                        Text("3. The final transcript is inserted at the original cursor. Press Esc to cancel.")
                        Text("Long microphone-only dictation: choose Start Long Dictation from the menu.")
                        Text("Conversation file: press \(ConversationShortcut.title) once to start and again to stop. The menu-bar timer shows when recording is active.")
                    }
                    .font(.callout)
                    .padding(6)
                }

                GroupBox("Official model download and terms") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Nemotron Speech Streaming English 0.6B Q8 is governed separately by the NVIDIA Open Model License Agreement.")
                            .font(.callout)
                        HStack {
                            Button("Download Page", action: coordinator.openModelPage)
                            Button("Model License", action: coordinator.openModelLicense)
                            Button("Runtime Source", action: coordinator.openRuntimePage)
                        }
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

    private var overallStatusText: String {
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
        if coordinator.speechEngineReady && coordinator.permissionStatus.allGranted && coordinator.globalShortcutOperational {
            return "checkmark.circle.fill"
        }
        if coordinator.speechEngineReady { return "exclamationmark.circle.fill" }
        return coordinator.state.symbolName
    }

    private var overallStatusColor: Color {
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
