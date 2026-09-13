import AppKit

/// Owns the single Settings window and routes deep links from the menu bar
/// and coordinator to the right page.
@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let unified: UnifiedLocalDictationWindowController

    init(coordinator: AppCoordinator) {
        unified = UnifiedLocalDictationWindowController(coordinator: coordinator)
        super.init(window: unified.window)
        unified.window?.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndActivate() {
        // Menu-bar apps normally stay out of the Dock and Command-Tab. While
        // Settings is open, behave like a normal app so the window remains easy
        // to recover after macOS brings System Settings to the front.
        unified.showAndActivate()
    }

    func showReadAloudVoice() { showAndActivate(); unified.showReadAloudVoice() }
    func showReadAloudAudio() { showAndActivate(); unified.showReadAloudAudio() }
    func showDictationPermissions() { showAndActivate(); unified.showDictationPermissions() }
    func showReadAloudSetup() { showAndActivate(); unified.showModels() }
    func showReadAloudSavedSpeech(at url: URL) { showAndActivate(); unified.showReadAloudSavedSpeech(at: url) }
    func showModelsAndStartup() { showAndActivate(); unified.showModels() }
    func showShortcuts() { showAndActivate(); unified.showShortcuts() }

    func windowWillClose(_ notification: Notification) {
        unified.stopObserving()
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
