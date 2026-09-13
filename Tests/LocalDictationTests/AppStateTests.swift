import XCTest
import CoreGraphics
@testable import LocalDictation

final class AppStateTests: XCTestCase {
    func testRealtimeEventAcceptanceRejectsStaleAndUnidentifiedConnections() {
        let active = UUID()
        XCTAssertTrue(AppCoordinator.acceptsRealtimeEvent(
            connectionID: active,
            expectedConnectionID: active,
            dictationEnabled: true,
            isUnloading: false
        ))
        XCTAssertFalse(AppCoordinator.acceptsRealtimeEvent(
            connectionID: UUID(),
            expectedConnectionID: active,
            dictationEnabled: true,
            isUnloading: false
        ))
        XCTAssertFalse(AppCoordinator.acceptsRealtimeEvent(
            connectionID: nil,
            expectedConnectionID: active,
            dictationEnabled: true,
            isUnloading: false
        ))
        XCTAssertFalse(AppCoordinator.acceptsRealtimeEvent(
            connectionID: active,
            expectedConnectionID: active,
            dictationEnabled: true,
            isUnloading: true
        ))
    }

    func testStateLabelsRemainUnambiguous() {
        XCTAssertEqual(AppState.ready.label, "Ready")
        XCTAssertEqual(AppState.recording(.pushToTalk).label, "Listening")
        XCTAssertEqual(AppState.recording(.handsFree).label, "Hands-free")
        XCTAssertEqual(AppState.recordingConversation.label, "Recording conversation")
        XCTAssertEqual(AppState.savingConversation.label, "Saving conversation…")
        XCTAssertEqual(AppState.inspectingMedia.label, "Reading media file…")
        XCTAssertEqual(AppState.transcribingFile.label, "Transcribing file…")
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
        let conversation = ShortcutBindings.standard.toggleConversation
        XCTAssertNotNil(conversation)
        XCTAssertTrue(conversation!.matches(keyCode: 8, flags: [.maskControl, .maskAlternate]))
        XCTAssertFalse(conversation!.matches(keyCode: 8, flags: [.maskControl, .maskAlternate, .maskCommand]))
        XCTAssertFalse(conversation!.matches(keyCode: 9, flags: [.maskControl, .maskAlternate]))
        XCTAssertEqual(conversation?.displayString, "⌃⌥C")
    }

    func testTextToSpeechShortcutsDoNotMatchModifiedOrDifferentKeys() {
        let read = ShortcutBindings.standard.readSelectedText
        let pause = ShortcutBindings.standard.pauseOrResumeReadback
        XCTAssertNotNil(read)
        XCTAssertNotNil(pause)
        XCTAssertTrue(read!.matches(keyCode: 15, flags: [.maskControl, .maskAlternate]))
        XCTAssertTrue(pause!.matches(keyCode: 35, flags: [.maskControl, .maskAlternate]))
        XCTAssertFalse(read!.matches(keyCode: 15, flags: [.maskControl, .maskAlternate, .maskCommand]))
        XCTAssertFalse(pause!.matches(keyCode: 15, flags: [.maskControl, .maskAlternate]))
    }

    func testTextToSpeechShortcutGateAllowsPauseButNotReadDuringPlayback() {
        XCTAssertFalse(TextToSpeechShortcutGate.readEnabled(settingsEnabled: true, canStart: false, isActive: true))
        XCTAssertTrue(TextToSpeechShortcutGate.pauseEnabled(settingsEnabled: true, isSpeaking: true))
        XCTAssertFalse(TextToSpeechShortcutGate.readEnabled(settingsEnabled: false, canStart: true, isActive: false))
        XCTAssertFalse(TextToSpeechShortcutGate.pauseEnabled(settingsEnabled: false, isSpeaking: true))
    }

    func testPreviewStatusUsesTextToSpeechStateInsteadOfASRStartupState() {
        XCTAssertEqual(TextToSpeechPreviewPresentation.statusText(for: .ready), "Ready")
        XCTAssertEqual(TextToSpeechPreviewPresentation.buttonTitle(for: .ready), " TTS")
        XCTAssertEqual(TextToSpeechPreviewPresentation.statusText(for: .unavailable("install it")), "Text to speech needs setup")
        XCTAssertEqual(TextToSpeechPreviewPresentation.buttonTitle(for: .error("worker failed")), " TTS error")
    }

    func testEscapeRoutesToDismissAnOtherwiseIdleTransientMessage() {
        XCTAssertTrue(GlobalHotkeyRouting.shouldRouteEscape(dictationActive: false, textToSpeechActive: false, transientMessageVisible: true))
        XCTAssertFalse(GlobalHotkeyRouting.shouldRouteEscape(dictationActive: false, textToSpeechActive: false, transientMessageVisible: false))
    }

    func testPendingSelectionCaptureConsumesRepeatedReadAndBlocksNewWorkUntilCancelled() {
        XCTAssertFalse(TextToSpeechSelectionCaptureGate.canBegin(canUseTextToSpeech: true, capturePending: true))
        XCTAssertTrue(TextToSpeechSelectionCaptureGate.shouldConsumeReadShortcut(capturePending: true, matchesReadShortcut: true))
        XCTAssertFalse(TextToSpeechSelectionCaptureGate.shouldConsumeReadShortcut(capturePending: false, matchesReadShortcut: true))
        XCTAssertTrue(TextToSpeechSelectionCaptureGate.canBegin(canUseTextToSpeech: true, capturePending: false))
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
            "Privacy_ScreenCapture"
        )
    }

    @MainActor
    func testPrivacyPaneFallbackRetainsTheSpecificPermissionAnchor() {
        XCTAssertEqual(
            PermissionManager.legacyPrivacyPaneURL(anchor: "Privacy_Microphone").absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
        XCTAssertEqual(
            PermissionManager.legacyPrivacyPaneURL(anchor: "Privacy_Accessibility").query,
            "Privacy_Accessibility"
        )
    }
}
