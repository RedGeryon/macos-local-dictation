import ApplicationServices
import XCTest
@testable import LocalDictation

final class SelectedTextCaptureTests: XCTestCase {
    func testUntrustedProcessRequiresAccessibilityPermissionBeforeSelectionCapture() {
        XCTAssertTrue(SelectedTextCapturePolicy.requiresAccessibilityPermission(isTrusted: false))
        XCTAssertFalse(SelectedTextCapturePolicy.requiresAccessibilityPermission(isTrusted: true))
    }

    func testBrowserWebAreaIsAnAllowedCopyFallbackButStaticTextIsNot() {
        XCTAssertTrue(SelectedTextCapturePolicy.supportsCopyFallback(role: "AXWebArea"))
        XCTAssertTrue(SelectedTextCapturePolicy.supportsCopyFallback(role: kAXTextAreaRole as String))
        XCTAssertFalse(SelectedTextCapturePolicy.supportsCopyFallback(role: "AXStaticText"))
        XCTAssertFalse(SelectedTextCapturePolicy.supportsCopyFallback(role: nil))
    }

    func testOnlyKnownBrowserBundlesReceiveTheAccessibilityRoleProbe() {
        XCTAssertTrue(BrowserAccessibilityActivationPolicy.allows("com.google.Chrome"))
        XCTAssertTrue(BrowserAccessibilityActivationPolicy.allows("com.apple.Safari"))
        XCTAssertFalse(BrowserAccessibilityActivationPolicy.allows("com.apple.Terminal"))
        XCTAssertFalse(BrowserAccessibilityActivationPolicy.allows(nil))
    }

    func testBrowserGetsAConservativeAccessibilityActivationRetryWindow() {
        XCTAssertEqual(BrowserAccessibilityActivationPolicy.retryMilliseconds(for: "com.google.Chrome"), 750)
        XCTAssertEqual(BrowserAccessibilityActivationPolicy.retryMilliseconds(for: "com.apple.Safari"), 750)
        XCTAssertEqual(BrowserAccessibilityActivationPolicy.retryMilliseconds(for: "com.apple.Terminal"), 150)
        XCTAssertEqual(BrowserAccessibilityActivationPolicy.retryMilliseconds(for: nil), 150)
    }

    func testSecureAndPasswordTargetsNeverUseCopyFallback() {
        XCTAssertTrue(SelectedTextCapturePolicy.isSecure(subrole: kAXSecureTextFieldSubrole as String, roleDescription: nil))
        XCTAssertTrue(SelectedTextCapturePolicy.isSecure(subrole: nil, roleDescription: "Password input"))
        XCTAssertFalse(SelectedTextCapturePolicy.isSecure(subrole: nil, roleDescription: "Web content"))
    }

    func testCopyFallbackRejectsItsOwnMarkerAndAnEmptyCopy() {
        XCTAssertNil(SelectedTextCapturePolicy.copiedText(nil, marker: "marker"))
        XCTAssertNil(SelectedTextCapturePolicy.copiedText("  \n", marker: "marker"))
        XCTAssertNil(SelectedTextCapturePolicy.copiedText("marker", marker: "marker"))
        XCTAssertEqual(SelectedTextCapturePolicy.copiedText("  Browser selection  ", marker: "marker"), "Browser selection")
    }

    func testClipboardRestorationRequiresUnchangedFocusContentAndChangeCount() {
        let copied = [("public.utf8-plain-text", Data("browser text".utf8))]
        XCTAssertTrue(SelectedTextClipboardRestorePolicy.shouldRestore(
            fallbackCopy: copied, current: copied, expectedChangeCount: 11, currentChangeCount: 11, targetUnchanged: true
        ))
        XCTAssertFalse(SelectedTextClipboardRestorePolicy.shouldRestore(
            fallbackCopy: copied, current: [("public.utf8-plain-text", Data("external".utf8))], expectedChangeCount: 11, currentChangeCount: 12, targetUnchanged: true
        ))
        XCTAssertFalse(SelectedTextClipboardRestorePolicy.shouldRestore(
            fallbackCopy: copied, current: copied, expectedChangeCount: 11, currentChangeCount: 11, targetUnchanged: false
        ))
    }

    func testNamedPasteboardRestoresAllFormatsForAnUnconsumedMarker() {
        let pasteboard = NSPasteboard(name: .init("org.localdictation.tests.\(UUID().uuidString)"))
        let plainText = NSPasteboard.PasteboardType.string
        let customType = NSPasteboard.PasteboardType("org.localdictation.tests.metadata")
        let original = NSPasteboardItem()
        original.setString("original text", forType: plainText)
        original.setData(Data([0xCA, 0xFE]), forType: customType)
        XCTAssertTrue(pasteboard.clearContents() >= 0)
        XCTAssertTrue(pasteboard.writeObjects([original]))
        let originalSnapshot = SelectedTextPasteboardStorage.snapshot(pasteboard)

        let marker = NSPasteboardItem()
        marker.setString("selection-marker", forType: plainText)
        marker.setData(Data([0x01]), forType: NSPasteboard.PasteboardType("org.localdictation.tests.marker"))
        XCTAssertTrue(pasteboard.clearContents() >= 0)
        XCTAssertTrue(pasteboard.writeObjects([marker]))
        let markerSnapshot = SelectedTextPasteboardStorage.snapshot(pasteboard)
        let markerCount = pasteboard.changeCount

        XCTAssertTrue(SelectedTextClipboardRestorePolicy.shouldRestore(
            fallbackCopy: SelectedTextPasteboardStorage.signature(markerSnapshot),
            current: SelectedTextPasteboardStorage.signature(SelectedTextPasteboardStorage.snapshot(pasteboard)),
            expectedChangeCount: markerCount,
            currentChangeCount: pasteboard.changeCount,
            targetUnchanged: true
        ))
        SelectedTextPasteboardStorage.restore(originalSnapshot, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: plainText), "original text")
        XCTAssertEqual(pasteboard.data(forType: customType), Data([0xCA, 0xFE]))
    }

    func testNamedPasteboardDoesNotRestoreOverANewerWrite() {
        let pasteboard = NSPasteboard(name: .init("org.localdictation.tests.\(UUID().uuidString)"))
        let marker = NSPasteboardItem()
        marker.setString("selection-marker", forType: .string)
        XCTAssertTrue(pasteboard.clearContents() >= 0)
        XCTAssertTrue(pasteboard.writeObjects([marker]))
        let markerSignature = SelectedTextPasteboardStorage.signature(
            SelectedTextPasteboardStorage.snapshot(pasteboard)
        )
        let markerCount = pasteboard.changeCount

        XCTAssertTrue(pasteboard.clearContents() >= 0)
        XCTAssertTrue(pasteboard.setString("external clipboard", forType: .string))
        XCTAssertFalse(SelectedTextClipboardRestorePolicy.shouldRestore(
            fallbackCopy: markerSignature,
            current: SelectedTextPasteboardStorage.signature(SelectedTextPasteboardStorage.snapshot(pasteboard)),
            expectedChangeCount: markerCount,
            currentChangeCount: pasteboard.changeCount,
            targetUnchanged: true
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), "external clipboard")
    }

    func testAccessibilityRangeRoundTripsUTF16OffsetsForEmojiSelection() {
        let expected = CFRange(location: 1, length: 4) // 🇺🇸 is four UTF-16 code units.
        let value = try! XCTUnwrap(AXValueCreate(.cfRange, [expected]))
        var actual = CFRange()
        XCTAssertTrue(AXValueGetValue(value, .cfRange, &actual))
        XCTAssertEqual(actual.location, expected.location)
        XCTAssertEqual(actual.length, expected.length)

        let text = "A🇺🇸B"
        let utf16Range = NSRange(location: actual.location, length: actual.length)
        XCTAssertEqual(Range(utf16Range, in: text).map { String(text[$0]) }, "🇺🇸")
    }
}
