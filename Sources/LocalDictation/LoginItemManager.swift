import Foundation
import ServiceManagement

/// Registers the app as a macOS login item through the system's own list
/// (System Settings › General › Login Items).
enum LoginItemManager {
    enum State: Equatable, Sendable {
        case enabled
        case disabled
        /// The user turned the item off in System Settings; only they can turn it back on.
        case requiresApproval
        case unsupported
    }

    /// Login items are only meaningful for a real app bundle that lives where
    /// macOS can relaunch it. The development preview and unit tests are excluded.
    static func isSupported(
        bundleURL: URL = Bundle.main.bundleURL,
        isPreview: Bool = LocalDictationPreviewIdentity.isPreview()
    ) -> Bool {
        guard !isPreview, bundleURL.pathExtension == "app" else { return false }
        return ApplicationInstallation.isInApplications(bundleURL)
    }

    static var state: State {
        guard isSupported() else { return .unsupported }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isSupported() else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
