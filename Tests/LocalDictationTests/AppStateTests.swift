import XCTest
import CoreGraphics
@testable import LocalDictation

final class AppStateTests: XCTestCase {
    func testStateLabelsRemainUnambiguous() {
        XCTAssertEqual(AppState.ready.label, "Ready")
        XCTAssertEqual(AppState.recording(.pushToTalk).label, "Listening")
        XCTAssertEqual(AppState.recording(.handsFree).label, "Hands-free")
        XCTAssertEqual(AppState.recordingConversation.label, "Recording conversation")
        XCTAssertEqual(AppState.savingConversation.label, "Saving conversation…")
        XCTAssertEqual(AppState.installationRequired.label, "Move to Applications")
        XCTAssertEqual(AppState.configurationRequired(.modelMissing).label, "Speech model required")
    }

    func testApplicationLocationRequiresAnApplicationsFolder() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertTrue(ApplicationInstallation.isInApplications(
            URL(fileURLWithPath: "/Applications/Local Dictation.app"),
            homeDirectory: home
        ))
        XCTAssertTrue(ApplicationInstallation.isInApplications(
            URL(fileURLWithPath: "/Users/example/Applications/Local Dictation.app"),
            homeDirectory: home
        ))
        XCTAssertFalse(ApplicationInstallation.isInApplications(
            URL(fileURLWithPath: "/Volumes/Local Dictation/Local Dictation.app"),
            homeDirectory: home
        ))
        XCTAssertFalse(ApplicationInstallation.isInApplications(
            URL(fileURLWithPath: "/Users/example/Desktop/Local Dictation.app"),
            homeDirectory: home
        ))
    }

    func testOnlyReadyStateReportsReady() {
        XCTAssertTrue(AppState.ready.isReady)
        XCTAssertFalse(AppState.loadingModel.isReady)
        XCTAssertFalse(AppState.recording(.pushToTalk).isReady)
    }

    func testPermissionStatusGuidesRequestsInRequiredOrder() {
        XCTAssertEqual(
            DictationPermissionStatus(
                microphone: false,
                accessibility: false
            ).firstMissing,
            .microphone
        )
        XCTAssertEqual(
            DictationPermissionStatus(
                microphone: true,
                accessibility: false
            ).firstMissing,
            .accessibility
        )
        XCTAssertTrue(
            DictationPermissionStatus(
                microphone: true,
                accessibility: true
            ).allGranted
        )
    }

    func testApplicationPasteFallbackIsLimitedToConfirmedEditorHost() {
        XCTAssertTrue(ApplicationPasteFallbackPolicy.allows("com.openai.codex"))
        XCTAssertFalse(ApplicationPasteFallbackPolicy.allows("com.example.editor"))
        XCTAssertFalse(ApplicationPasteFallbackPolicy.allows(nil))
    }

    func testConversationShortcutIsControlOptionCOnly() {
        XCTAssertTrue(GlobalShortcutMatcher.isConversationToggle(
            keyCode: 8,
            flags: [.maskControl, .maskAlternate]
        ))
        XCTAssertFalse(GlobalShortcutMatcher.isConversationToggle(
            keyCode: 8,
            flags: [.maskControl, .maskAlternate, .maskCommand]
        ))
        XCTAssertFalse(GlobalShortcutMatcher.isConversationToggle(
            keyCode: 9,
            flags: [.maskControl, .maskAlternate]
        ))
        XCTAssertEqual(ConversationShortcut.title, "Control–Option–C")
    }

    @MainActor
    func testPrivacyLinksUseCurrentSystemSettingsExtension() {
        XCTAssertEqual(
            PermissionManager.privacyPaneURL(anchor: "Privacy_Accessibility").absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
        XCTAssertEqual(
            PermissionManager.systemAudioPrivacyAnchor(majorVersion: 25),
            "Privacy_ScreenCapture"
        )
        XCTAssertEqual(
            PermissionManager.systemAudioPrivacyAnchor(majorVersion: 26),
            "Privacy_AudioCapture"
        )
    }
}
