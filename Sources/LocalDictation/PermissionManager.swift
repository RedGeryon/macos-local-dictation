@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
import Foundation

enum DictationPermission: CaseIterable, Equatable, Sendable {
    case microphone
    case accessibility
}

enum MicrophonePermissionState: Equatable, Sendable {
    case notDetermined, denied, restricted, authorized

    var isGranted: Bool { self == .authorized }
    var needsSettings: Bool { self == .denied || self == .restricted }

    static func current() -> Self {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }
}

enum SystemAudioPermissionState: Equatable, Sendable {
    case unknown
    case requested
    case verifiedCurrentCapture
}

struct DictationPermissionStatus: Equatable, Sendable {
    let microphone: Bool
    /// Raw TCC Accessibility trust, independent of whether our event tap started.
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
    var microphoneState: MicrophonePermissionState { .current() }

    var status: DictationPermissionStatus {
        DictationPermissionStatus(
            microphone: microphoneState.isGranted,
            accessibility: accessibilityGranted
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

    @discardableResult
    func openSettings(for permission: DictationPermission) -> Bool {
        switch permission {
        case .microphone: return openMicrophoneSettings()
        case .accessibility: return openAccessibilitySettings()
        }
    }

    @discardableResult
    func openMicrophoneSettings() -> Bool {
        openPrivacyPane("Privacy_Microphone")
    }

    @discardableResult
    func openAccessibilitySettings() -> Bool {
        openPrivacyPane("Privacy_Accessibility")
    }

    @discardableResult
    func openSystemAudioSettings() -> Bool {
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return openPrivacyPane(Self.systemAudioPrivacyAnchor(majorVersion: majorVersion))
    }

    private func openPrivacyPane(_ anchor: String) -> Bool {
        let workspace = NSWorkspace.shared
        if workspace.open(Self.privacyPaneURL(anchor: anchor)) { return true }
        // Older System Settings versions still accept the legacy privacy URL.
        return workspace.open(Self.legacyPrivacyPaneURL(anchor: anchor))
    }

    static func privacyPaneURL(anchor: String) -> URL {
        URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        )!
    }

    static func legacyPrivacyPaneURL(anchor: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static func systemAudioPrivacyAnchor(majorVersion: Int) -> String {
        "Privacy_ScreenCapture"
    }
}
