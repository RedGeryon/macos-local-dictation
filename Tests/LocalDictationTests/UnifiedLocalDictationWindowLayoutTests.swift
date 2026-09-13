import AppKit
import XCTest
@testable import LocalDictation

final class UnifiedLocalDictationWindowLayoutTests: XCTestCase {
    @MainActor func testDictationPageFitsTheDetailPane() throws {
        _ = NSApplication.shared
        let controller = UnifiedLocalDictationWindowController(coordinator: AppCoordinator())
        let window = try XCTUnwrap(controller.window)
        controller.showAndActivate(); window.setContentSize(window.minSize)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(window.contentView?.bounds.height ?? 0, 560)
        let content = try XCTUnwrap(find("unified.content", in: window.contentView))
        for id in ["dictation.shortcutHint", "dictation.language", "dictation.punctuation"] {
            let view = try XCTUnwrap(find(id, in: content), "Missing \(id)")
            let frame = view.convert(view.bounds, to: content)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, content.bounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, content.bounds.maxX)
        }
    }

    @MainActor func testReadAloudIsEmbeddedAndReachableAtMinimumSize() throws {
        _ = NSApplication.shared
        let controller = UnifiedLocalDictationWindowController(coordinator: AppCoordinator())
        let window = try XCTUnwrap(controller.window)
        controller.showAndActivate()
        window.setContentSize(window.minSize)
        let sidebar = try XCTUnwrap(find("unified.sidebar", in: window.contentView) as? NSTableView)
        sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(find("unified.content", in: window.contentView))
        let voice = try XCTUnwrap(find("tts.Save & Use Voice", in: content))
        let outer = try XCTUnwrap(find("unified.detailScroll", in: window.contentView) as? NSScrollView)
        let outerRect = voice.convert(voice.bounds, to: content)
        outer.contentView.scroll(to: outerRect.origin)
        outer.reflectScrolledClipView(outer.contentView)
        voice.scrollToVisible(voice.bounds)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(voice.isHidden)
        XCTAssertGreaterThan(voice.bounds.width, 0)
        var ancestor = voice.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView {
                let frame = voice.convert(voice.bounds, to: scroll.contentView)
                XCTAssertTrue(scroll.contentView.bounds.contains(frame), "voice action is clipped by a scroll viewport")
            }
            ancestor = view.superview
        }
    }

    @MainActor func testModelsPageContainsIndependentControlsAtMinimumSize() throws {
        _ = NSApplication.shared
        let controller = UnifiedLocalDictationWindowController(coordinator: AppCoordinator())
        let window = try XCTUnwrap(controller.window)
        controller.showAndActivate()
        window.setContentSize(window.minSize)
        controller.showModels(); window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(find("unified.content", in: window.contentView))
        content.layoutSubtreeIfNeeded()
        let sidebar = try XCTUnwrap(find("unified.sidebarScroll", in: window.contentView))
        let detail = try XCTUnwrap(find("unified.detailScroll", in: window.contentView))
        XCTAssertGreaterThanOrEqual(sidebar.frame.width, 190)
        XCTAssertGreaterThanOrEqual(detail.frame.width, 500)
        XCTAssertGreaterThanOrEqual(detail.frame.height, 500)
        for id in ["models.asr.enabled", "models.asr.startup", "models.asr.model", "models.asr.add", "models.tts.enabled", "models.tts.startup", "models.tts.model", "models.tts.add"] {
            let control = try XCTUnwrap(find(id, in: content), "Missing \(id)")
            XCTAssertFalse(control.isHidden)
            XCTAssertGreaterThan(control.bounds.width, 0, "\(id) has no width")
            let frame = control.convert(control.bounds, to: content)
            XCTAssertGreaterThanOrEqual(frame.minX, content.bounds.minX, "\(id) is clipped on the left")
            XCTAssertLessThanOrEqual(frame.maxX, content.bounds.maxX, "\(id) is clipped on the right")
        }
    }

    @MainActor func testShortcutsPageListsEveryActionAndFitsAtMinimumSize() throws {
        _ = NSApplication.shared
        let controller = UnifiedLocalDictationWindowController(coordinator: AppCoordinator())
        let window = try XCTUnwrap(controller.window)
        controller.showAndActivate()
        window.setContentSize(window.minSize)
        controller.showShortcuts()
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(find("unified.content", in: window.contentView))
        let sidebar = try XCTUnwrap(find("unified.sidebar", in: window.contentView) as? NSTableView)
        XCTAssertEqual(sidebar.selectedRow, UnifiedLocalDictationWindowController.Page.shortcuts.rawValue)
        for id in ["shortcuts.quickDictationMode", "shortcuts.toggleConversation", "shortcuts.readSelectedText", "shortcuts.pauseOrResumeReadback", "shortcuts.ttsEnabled", "shortcuts.reset"] {
            let view = try XCTUnwrap(find(id, in: content), "Missing \(id)")
            XCTAssertFalse(view.isHidden)
            let frame = view.convert(view.bounds, to: content)
            XCTAssertGreaterThan(frame.width, 0, "\(id) has no width")
            XCTAssertGreaterThanOrEqual(frame.minX, content.bounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, content.bounds.maxX, "\(id) is clipped on the right")
        }
        let conversation = try XCTUnwrap(find("shortcuts.toggleConversation", in: content) as? ShortcutRecorderView)
        XCTAssertEqual(conversation.shortcut, ShortcutBindings.standard.toggleConversation)
    }

    @MainActor func testQuickDictationPopupSwitchesBetweenFnAndACustomCombination() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator()
        coordinator.resetShortcutBindings()
        let controller = UnifiedLocalDictationWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(controller.window)
        controller.showShortcuts()
        window.contentView?.layoutSubtreeIfNeeded()
        var content = try XCTUnwrap(find("unified.content", in: window.contentView))
        XCTAssertNil(find("shortcuts.quickDictation", in: content), "Fn mode shows no key-combination field")

        var popup = try XCTUnwrap(find("shortcuts.quickDictationMode", in: content) as? NSPopUpButton)
        popup.selectItem(at: 1)
        _ = try XCTUnwrap(popup.target as? NSObject).perform(try XCTUnwrap(popup.action), with: popup)
        XCTAssertEqual(coordinator.settings.bindings.quickDictation, .keyboardShortcut(ShortcutBindings.legacyControlOptionSpace))
        content = try XCTUnwrap(find("unified.content", in: window.contentView))
        let recorder = try XCTUnwrap(find("shortcuts.quickDictation", in: content) as? ShortcutRecorderView)
        XCTAssertEqual(recorder.shortcut, ShortcutBindings.legacyControlOptionSpace)

        popup = try XCTUnwrap(find("shortcuts.quickDictationMode", in: content) as? NSPopUpButton)
        popup.selectItem(at: 0)
        _ = try XCTUnwrap(popup.target as? NSObject).perform(try XCTUnwrap(popup.action), with: popup)
        XCTAssertEqual(coordinator.settings.bindings.quickDictation, .functionKey)
        coordinator.resetShortcutBindings()
    }

    @MainActor func testRecorderClearsAndRecordsThroughItsCallbacks() throws {
        _ = NSApplication.shared
        let recorder = ShortcutRecorderView()
        recorder.shortcut = ShortcutBindings.standard.readSelectedText
        var changes: [KeyboardShortcut?] = []
        recorder.onChange = { changes.append($0) }
        var recordingStates: [Bool] = []
        recorder.onRecordingStateChange = { recordingStates.append($0) }
        recorder.beginRecording()
        XCTAssertTrue(recorder.isRecording)
        recorder.cancelRecording()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recordingStates, [true, false])
        XCTAssertTrue(changes.isEmpty, "Cancel must not change the binding")
        XCTAssertEqual(recorder.shortcut, ShortcutBindings.standard.readSelectedText)
    }

    @MainActor private func find(_ id: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }
}
