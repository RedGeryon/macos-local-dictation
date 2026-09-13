import AppKit
import Foundation
import OSLog
@preconcurrency import UserNotifications

/// Posts a system notification when a transcript is saved. Clicking it opens
/// the file. Notifications are only available to a real app bundle, so the
/// unit-test host and command-line runs skip them silently.
@MainActor
final class TranscriptNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let fileURLKey = "fileURL"
    nonisolated static let category = "transcript-saved"

    private let logger = Logger(subsystem: "org.localdictation.app", category: "Notifications")
    private let isAvailable: Bool
    private var authorizationRequested = false

    init(bundleURL: URL = Bundle.main.bundleURL) {
        isAvailable = bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
        super.init()
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Announces a saved conversation transcript.
    func notifyConversationSaved(at fileURL: URL) {
        post(
            title: "Conversation transcript saved",
            body: fileURL.lastPathComponent,
            fileURL: fileURL
        )
    }

    private func post(title: String, body: String, fileURL: URL) {
        guard isAvailable else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            if !self.authorizationRequested {
                self.authorizationRequested = true
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                guard granted else { return }
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = Self.category
            content.userInfo = [Self.fileURLKey: fileURL.path]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                self.logger.error("NOTIFICATION_FAILED error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo[Self.fileURLKey] as? String {
            let url = URL(fileURLWithPath: path)
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even while the app is frontmost.
        completionHandler([.banner, .sound])
    }
}
