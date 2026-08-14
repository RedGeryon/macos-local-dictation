@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
import Foundation

enum DictationPermission: CaseIterable, Equatable, Sendable {
    case microphone
    case accessibility
}

struct DictationPermissionStatus: Equatable, Sendable {
    let microphone: Bool
    let accessibility: Bool

    var allGranted: Bool { microphone && accessibility }

    var firstMissing: DictationPermission? {
        if !microphone { return .microphone }
        if !accessibility { return .accessibility }
        return nil
    }

    func isGranted(_ permission: DictationPermission) -> Bool {
        switch permission {
        case .microphone: microphone
        case .accessibility: accessibility
        }
    }
}

@MainActor
final class PermissionManager {
    var systemAudioGranted: Bool { CGPreflightScreenCaptureAccess() }
    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    var status: DictationPermissionStatus {
        status(accessibilityOperational: false)
    }

    func status(accessibilityOperational: Bool) -> DictationPermissionStatus {
        DictationPermissionStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: accessibilityGranted || accessibilityOperational
        )
    }

    @discardableResult
    func requestMicrophone() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return status.microphone
    }

    @discardableResult
    func requestAccessibility() -> Bool {
        guard !accessibilityGranted else { return true }
        _ = AXIsProcessTrustedWithOptions([
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary)
        return accessibilityGranted
    }

    func openSettings(for permission: DictationPermission) {
        switch permission {
        case .microphone: openMicrophoneSettings()
        case .accessibility: openAccessibilitySettings()
        }
    }

    func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func openSystemAudioSettings() {
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        openPrivacyPane(Self.systemAudioPrivacyAnchor(majorVersion: majorVersion))
    }

    private func openPrivacyPane(_ anchor: String) {
        NSWorkspace.shared.open(Self.privacyPaneURL(anchor: anchor))
    }

    static func privacyPaneURL(anchor: String) -> URL {
        URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        )!
    }

    static func systemAudioPrivacyAnchor(majorVersion: Int) -> String {
        majorVersion >= 26 ? "Privacy_AudioCapture" : "Privacy_ScreenCapture"
    }
}
