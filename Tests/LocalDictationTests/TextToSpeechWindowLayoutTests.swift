import AppKit
import XCTest
@testable import LocalDictation

final class TextToSpeechWindowLayoutTests: XCTestCase {
    @MainActor func testVoiceAndAudioPagesFitAtMinimumSize() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator()
        let controller = TextToSpeechWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false)
        controller.showVoicePage(); window.contentView?.layoutSubtreeIfNeeded()
        try assertVisible(["tts.tabs", "tts.currentVoice", "tts.voicePicker", "tts.voicePrompt", "tts.draftStatus", "tts.Preview Voice", "tts.Save & Use Voice"], window)
        controller.showAudioPage(); window.contentView?.layoutSubtreeIfNeeded()
        try assertVisible(["tts.tabs", "tts.currentVoice", "tts.changeVoice", "tts.editor", "tts.Listen", "tts.Save Audio…"], window)
    }

    @MainActor func testExpandedSettingsAndRecoveryFitAtMinimumSize() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator()
        let controller = TextToSpeechWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false); controller.showVoicePage()
        let disclosure = try XCTUnwrap(find("tts.settingsDisclosure", window.contentView) as? NSButton)
        disclosure.performClick(nil); window.contentView?.layoutSubtreeIfNeeded()
        try assertVisible(["tts.settingsDisclosure", "tts.pronunciations", "tts.openAudioFolder"], window, scrollIntoView: true)
        let status = try XCTUnwrap(find("tts.status", window.contentView) as? NSTextField)
        status.stringValue = "The local text-to-speech worker did not become ready before its startup deadline. Review the detailed error and retry."
        let detail = try XCTUnwrap(find("tts.setupDetail", window.contentView) as? NSTextField)
        detail.stringValue = "Install the local runtime and model, then retry. This message must wrap without clipping recovery controls."; detail.isHidden = false
        let retry = try XCTUnwrap(find("tts.retry", window.contentView) as? NSButton); retry.isHidden = false
        let hint = try XCTUnwrap(find("tts.shortcutsAccessibilityHint", window.contentView) as? NSTextField); hint.isHidden = false
        let permission = try XCTUnwrap(find("tts.allowAccessibility", window.contentView) as? NSButton); permission.isHidden = false
        window.contentView?.layoutSubtreeIfNeeded()
        try assertVisible(["tts.status", "tts.setupDetail", "tts.retry", "tts.shortcutsAccessibilityHint", "tts.allowAccessibility"], window, scrollIntoView: true)
        XCTAssertGreaterThan(status.frame.height, 16)
    }

    @MainActor private func assertVisible(_ ids: [String], _ window: NSWindow, scrollIntoView: Bool = false) throws {
        let content = try XCTUnwrap(window.contentView)
        for id in ids {
            let view = try XCTUnwrap(find(id, content), "Missing \(id)")
            if scrollIntoView { view.scrollToVisible(view.bounds); content.layoutSubtreeIfNeeded() }
            XCTAssertFalse(view.isHidden, "\(id) hidden")
            let frame = view.convert(view.bounds, to: content)
            XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(content.bounds.contains(frame), "\(id) clipped by content")
            var ancestor = view.superview
            while let current = ancestor {
                if let scroll = current as? NSScrollView {
                    let inViewport = view.convert(view.bounds, to: scroll.contentView)
                    XCTAssertTrue(scroll.contentView.bounds.contains(inViewport), "\(id) clipped by scroll viewport frame=\(inViewport) viewport=\(scroll.contentView.bounds)")
                }
                ancestor = current.superview
            }
        }
    }
    @MainActor private func find(_ id: String, _ view: NSView?) -> NSView? {
        guard let view else { return nil }; if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, $0) }.first
    }
}
