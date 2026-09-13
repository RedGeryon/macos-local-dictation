import AppKit
import XCTest
@testable import LocalDictation

final class MenuBarControllerTests: XCTestCase {
    @MainActor func testSpeechToTextSectionPrecedesTextToSpeechAndSharedSettings() throws {
        _ = NSApplication.shared
        let menu = MenuBarController(coordinator: AppCoordinator()).menuTitlesForTesting()
        let stt = try XCTUnwrap(menu.firstIndex(of: "Speech to Text"))
        let tts = try XCTUnwrap(menu.firstIndex(of: "Text to Speech"))
        let settings = try XCTUnwrap(menu.firstIndex(of: "Settings…"))
        XCTAssertLessThan(stt, tts)
        XCTAssertLessThan(tts, settings)
    }

    @MainActor func testBothFeaturesShowAStatusRowDirectlyUnderTheirHeader() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator()
        let menu = try XCTUnwrap(MenuBarController(coordinator: coordinator).menuForTesting())
        let items = menu.items
        for header in ["Speech to Text", "Text to Speech"] {
            let index = try XCTUnwrap(items.firstIndex(where: { $0.title == header }), "Missing \(header)")
            XCTAssertTrue(items[index].isSectionHeader, "\(header) should be a section header")
            let status = items[index + 1]
            XCTAssertTrue(status.identifier?.rawValue.hasPrefix("menu.status.") ?? false, "\(header) must be followed by its status row")
            XCTAssertNotNil(status.image, "\(header) status row needs a colored status dot")
            XCTAssertNotNil(status.action, "\(header) status row should open the page that explains it")
        }
        XCTAssertFalse(items.contains(where: { $0.title == "Local Dictation" }), "The menu no longer repeats the app name as a fake title row")
        let quit = try XCTUnwrap(items.last)
        XCTAssertEqual(quit.title, "Quit Local Dictation")
    }

    @MainActor func testMenuKeyEquivalentsFollowTheUserBindings() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator()
        var bindings = coordinator.settings.bindings
        bindings.readSelectedText = KeyboardShortcut(keyCode: 15, modifiers: [.command, .shift])
        coordinator.setShortcutBindings(bindings)
        let menu = try XCTUnwrap(MenuBarController(coordinator: coordinator).menuForTesting())
        let read = try XCTUnwrap(menu.items.first(where: { $0.title == "Read Selected Text" }))
        XCTAssertEqual(read.keyEquivalent, "r")
        XCTAssertEqual(read.keyEquivalentModifierMask, [.command, .shift])
        coordinator.resetShortcutBindings()
    }

    @MainActor func testExplicitlyDisabledReadCommandStaysDisabledWhenMenuUpdates() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator()
        let menu = try XCTUnwrap(MenuBarController(coordinator: coordinator).menuForTesting())
        let read = try XCTUnwrap(menu.items.first(where: { $0.title == "Read Selected Text" }))
        XCTAssertFalse(read.isEnabled)
        menu.update()
        XCTAssertFalse(read.isEnabled)
    }
}
