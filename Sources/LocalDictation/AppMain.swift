import AppKit

@main
struct LocalDictationMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator?.refreshPermissions()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator?.serverManager.isRunning == true else {
            return .terminateNow
        }
        coordinator?.quit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.applicationWillTerminate()
    }
}
