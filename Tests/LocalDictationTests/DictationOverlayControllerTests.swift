import AppKit
import XCTest
@testable import LocalDictation

final class DictationOverlayControllerTests: XCTestCase {
    @MainActor
    func testTransientMessageAutoDismissesWhileASRWouldStillBeStarting() async {
        _ = NSApplication.shared
        let overlay = DictationOverlayController()
        let dismissed = expectation(description: "transient message dismisses")
        overlay.showTransientMessage("No selected text", duration: .milliseconds(25)) { _ in
            dismissed.fulfill()
        }
        XCTAssertTrue(overlay.hasActiveMessage)
        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertFalse(overlay.hasActiveMessage)
        XCTAssertFalse(overlay.isVisible)
    }

    @MainActor
    func testStaleRecoverableMessageCannotHideNewListeningOverlay() {
        _ = NSApplication.shared
        let overlay = DictationOverlayController()
        let staleMessage = overlay.showMessage("No selected text")
        XCTAssertTrue(overlay.hasActiveMessage)
        overlay.showListening(mode: .pushToTalk)
        overlay.hideMessage(staleMessage)
        XCTAssertFalse(overlay.hasActiveMessage)
        XCTAssertTrue(overlay.isVisible)
    }
}
