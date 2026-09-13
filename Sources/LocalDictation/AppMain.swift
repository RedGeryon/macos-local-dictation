import AppKit

@main
struct LocalDictationMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        // Development aid: LOCAL_DICTATION_APPEARANCE=dark|light forces one
        // appearance so both themes can be checked without changing the Mac.
        switch ProcessInfo.processInfo.environment["LOCAL_DICTATION_APPEARANCE"] {
        case "dark": application.appearance = NSAppearance(named: .darkAqua)
        case "light": application.appearance = NSAppearance(named: .aqua)
        default: break
        }
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
        if coordinator?.terminationInProgress == true {
            return .terminateNow
        }
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
