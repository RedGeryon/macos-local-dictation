import AppKit
import XCTest
@testable import LocalDictation

final class FeatureImprovementsTests: XCTestCase {
    // MARK: Dictation history

    func testHistoryKeepsNewestFirstCapsAtFiveAndDropsDuplicates() {
        var history = DictationHistory()
        for index in 1...7 { history.record(rawTranscript: "raw \(index)", text: "Sentence \(index)") }
        XCTAssertEqual(history.entries.count, DictationHistory.capacity)
        XCTAssertEqual(history.entries.map(\.text), ["Sentence 7", "Sentence 6", "Sentence 5", "Sentence 4", "Sentence 3"])
        history.record(rawTranscript: "raw 5 again", text: "Sentence 5")
        XCTAssertEqual(history.entries.first?.text, "Sentence 5", "Re-dictating moves the sentence to the top instead of duplicating it")
        XCTAssertEqual(history.entries.count, DictationHistory.capacity)
        history.record(rawTranscript: "", text: "   \n ")
        XCTAssertEqual(history.entries.count, DictationHistory.capacity, "Blank results are not recorded")
    }

    func testHistoryMenuTitleIsOneShortLine() {
        var history = DictationHistory()
        history.record(rawTranscript: "", text: "First line\nsecond line that goes on and on and on for quite a while longer than the limit")
        let title = try! XCTUnwrap(history.newest?.menuTitle)
        XCTAssertFalse(title.contains("\n"))
        XCTAssertLessThanOrEqual(title.count, 50)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    @MainActor func testMenuListsRecentDictationsOnlyWhenTheSessionHasSome() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator(modelCatalogConfiguration: .init(
            supportDirectory: FileManager.default.temporaryDirectory,
            ttsModelsDirectory: FileManager.default.temporaryDirectory,
            ttsRuntimeDirectory: FileManager.default.temporaryDirectory,
            defaults: .standard,
            initialState: .ready
        ))
        let controller = MenuBarController(coordinator: coordinator)
        XCTAssertFalse(controller.menuTitlesForTesting().contains("Recent Dictations"))
        coordinator.recordDictationForTesting(rawTranscript: "hello there", text: "Hello there.")
        let menu = try XCTUnwrap(controller.menuForTesting())
        let recent = try XCTUnwrap(menu.items.first(where: { $0.title == "Recent Dictations" }))
        XCTAssertEqual(recent.submenu?.items.first?.title, "Hello there.")
        XCTAssertNotNil(recent.submenu?.items.first?.representedObject as? UUID)
        XCTAssertTrue(menu.items.contains(where: { $0.title == "Paste Last Quick Dictation" }))
    }

    // MARK: Long Dictation shortcut

    func testLongDictationHasADefaultBindingAndOlderSavedBindingsReceiveIt() throws {
        XCTAssertEqual(ShortcutBindings.standard.toggleLongDictation, KeyboardShortcut(keyCode: 37, modifiers: [.control, .option]))
        XCTAssertTrue(ShortcutAction.allCases.contains(.toggleLongDictation))
        let legacyJSON = """
        {"quickDictation":{"functionKey":{}},"toggleConversation":{"keyCode":8,"modifiers":3},"readSelectedText":{"keyCode":15,"modifiers":3},"pauseOrResumeReadback":{"keyCode":35,"modifiers":3}}
        """
        let decoded = try JSONDecoder().decode(ShortcutBindings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.toggleLongDictation, ShortcutBindings.standard.toggleLongDictation, "A binding saved before the action existed gets the default")
        XCTAssertEqual(decoded.toggleConversation, ShortcutBindings.standard.toggleConversation)
    }

    func testAClearedBindingStaysClearedAcrossSaveAndLoad() throws {
        var bindings = ShortcutBindings.standard
        bindings.toggleLongDictation = nil
        let data = try JSONEncoder().encode(bindings)
        let decoded = try JSONDecoder().decode(ShortcutBindings.self, from: data)
        XCTAssertNil(decoded.toggleLongDictation)
        XCTAssertEqual(decoded, bindings)
    }

    @MainActor func testShortcutsPageShowsTheLongDictationField() throws {
        _ = NSApplication.shared
        let controller = UnifiedLocalDictationWindowController(coordinator: AppCoordinator())
        controller.showShortcuts()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(find("unified.content", in: controller.window?.contentView))
        let recorder = try XCTUnwrap(find("shortcuts.toggleLongDictation", in: content) as? ShortcutRecorderView)
        XCTAssertEqual(recorder.shortcut?.displayString, "⌃⌥L")
    }

    // MARK: Idle unloading

    func testIdleUnloadOnlySchedulesForALoadedIdleFeature() {
        XCTAssertFalse(IdleUnloadPolicy.shouldSchedule(minutes: nil, engineReady: true, busy: false), "Keep loaded")
        XCTAssertFalse(IdleUnloadPolicy.shouldSchedule(minutes: 0, engineReady: true, busy: false))
        XCTAssertFalse(IdleUnloadPolicy.shouldSchedule(minutes: 15, engineReady: false, busy: false), "Nothing to unload")
        XCTAssertFalse(IdleUnloadPolicy.shouldSchedule(minutes: 15, engineReady: true, busy: true), "Never during work")
        XCTAssertTrue(IdleUnloadPolicy.shouldSchedule(minutes: 15, engineReady: true, busy: false))
        XCTAssertEqual(IdleUnloadPolicy.title(for: nil), "Keep loaded")
        XCTAssertEqual(IdleUnloadPolicy.title(for: 30), "After 30 minutes idle")
    }

    func testIdleUnloadSettingSurvivesFeatureTogglesAndOlderSavedSettings() throws {
        let suite = "LocalDictationTests.FeatureImprovements.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = LocalFeatureSettings()
        XCTAssertNil(LocalFeatureSettings.load(defaults: defaults).dictation.idleUnloadMinutes)
        XCTAssertNil(settings.dictation.idleUnloadMinutes)
        settings.dictation.idleUnloadMinutes = 15
        settings.readAloud.idleUnloadMinutes = 5
        settings.persist(defaults: defaults)
        XCTAssertEqual(LocalFeatureSettings.load(defaults: defaults), settings)

        let legacy = Data(#"{"dictation":{"enabled":true,"loadAtStartup":true},"readAloud":{"enabled":true,"loadAtStartup":false,"model":"qwen-1.7b-8bit"}}"#.utf8)
        let decoded = try JSONDecoder().decode(LocalFeatureSettings.self, from: legacy)
        XCTAssertNil(decoded.dictation.idleUnloadMinutes, "Older settings default to keeping models loaded")
        XCTAssertEqual(decoded.readAloud.model, .eightBit)
    }

    @MainActor func testModelsPageOffersIdleUnloadAndLoginControls() throws {
        _ = NSApplication.shared
        let controller = UnifiedLocalDictationWindowController(coordinator: AppCoordinator())
        controller.showModels()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(find("unified.content", in: controller.window?.contentView))
        let asr = try XCTUnwrap(find("models.asr.idleUnload", in: content) as? NSPopUpButton)
        XCTAssertEqual(asr.itemTitles.first, "Keep loaded")
        XCTAssertEqual(asr.itemTitles.count, IdleUnloadPolicy.choices.count)
        XCTAssertNotNil(find("models.tts.idleUnload", in: content))
        let login = try XCTUnwrap(find("models.openAtLogin", in: content) as? NSButton)
        XCTAssertFalse(login.isEnabled, "The test host is not an installed app, so the login item is unavailable")
    }

    // MARK: Menu-bar glyph

    func testMenuBarGlyphFollowsActivity() {
        XCTAssertEqual(MenuBarController.statusSymbolName(state: .ready, textToSpeech: .ready), "waveform.badge.mic")
        XCTAssertEqual(MenuBarController.statusSymbolName(state: .recording(.pushToTalk), textToSpeech: .ready), "mic.fill")
        XCTAssertEqual(MenuBarController.statusSymbolName(state: .recordingConversation, textToSpeech: .idle), "mic.fill")
        XCTAssertEqual(MenuBarController.statusSymbolName(state: .ready, textToSpeech: .speaking(paused: false)), "speaker.wave.2.fill")
        XCTAssertEqual(MenuBarController.statusSymbolName(state: .ready, textToSpeech: .generating), "speaker.wave.2.fill")
        XCTAssertEqual(MenuBarController.statusSymbolName(state: .transcribingFile, textToSpeech: .ready), "doc.text.magnifyingglass")
    }

    // MARK: Voices

    func testRyanAndVivianAreTheTwoPrimaryVoices() {
        XCTAssertEqual(TextToSpeechVoice.primaryVoiceIDs, ["ryan", "vivian"])
        XCTAssertEqual(TextToSpeechVoice.placeholder(id: "vivian").name, "Vivian")
        XCTAssertFalse(TextToSpeechVoice.primaryVoiceIDs.contains("designed-narrator"), "The designed voice needs extra model passes and is no longer a default")
    }

    func testLoginItemIsUnsupportedOutsideAnInstalledAppBundle() {
        XCTAssertFalse(LoginItemManager.isSupported(bundleURL: URL(fileURLWithPath: "/tmp/xctest"), isPreview: false))
        XCTAssertFalse(LoginItemManager.isSupported(bundleURL: URL(fileURLWithPath: "/Applications/Local Dictation.app"), isPreview: true))
        XCTAssertTrue(LoginItemManager.isSupported(bundleURL: URL(fileURLWithPath: "/Applications/Local Dictation.app"), isPreview: false))
    }

    @MainActor private func find(_ id: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }
}
