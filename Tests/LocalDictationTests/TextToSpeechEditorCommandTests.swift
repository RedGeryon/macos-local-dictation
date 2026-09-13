import AppKit
import XCTest
@testable import LocalDictation

final class TextToSpeechEditorCommandTests: XCTestCase {
    @MainActor
    func testPromptEditorHandlesCommandSelectAllWithoutAnExistingMainMenu() throws {
        _ = NSApplication.shared
        let originalMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = originalMenu }
        NSApp.mainMenu = nil

        let controller = TextToSpeechWindowController(coordinator: AppCoordinator())
        let promptScroll = try XCTUnwrap(find("tts.voicePrompt", in: controller.window?.contentView) as? NSScrollView)
        let editor = try XCTUnwrap(promptScroll.documentView as? NSTextView)
        try XCTUnwrap(controller.window).makeFirstResponder(editor)
        editor.string = "Select every word"
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let commandA = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        XCTAssertTrue(editor.performKeyEquivalent(with: commandA))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
    }

    @MainActor
    private func find(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { self.find(identifier, in: $0) }.first
    }
}
