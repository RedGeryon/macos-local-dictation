import Foundation
import XCTest
@testable import LocalDictation

final class ChildProcessGuardTests: XCTestCase {
    func testOnlyBundledEngineHelpersWhoseParentIsLaunchdCountAsOrphans() {
        let bundled = "/Applications/Local Dictation.app/Contents/Resources/Engine/bin/nemo-speech"
        XCTAssertTrue(OrphanedHelperReaper.isHelper(path: bundled, parentProcessID: 1))
        XCTAssertFalse(OrphanedHelperReaper.isHelper(path: bundled, parentProcessID: 4242), "A helper with a live parent is not an orphan")
        XCTAssertFalse(OrphanedHelperReaper.isHelper(path: "/opt/homebrew/bin/nemo-speech", parentProcessID: 1), "Only app-bundled helpers are reaped")
        XCTAssertFalse(OrphanedHelperReaper.isHelper(path: "/Applications/Local Dictation.app/Contents/Resources/Engine/bin/other", parentProcessID: 1))
    }

    func testWatchdogScriptTerminatesTheHelperOnceTheAppIsGone() throws {
        // A helper that would otherwise live for a minute.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        helper.arguments = ["60"]
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }

        // An "app" that exits immediately, so its process ID is dead by the time the watchdog polls.
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try app.run()
        app.waitUntilExit()

        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", ChildProcessWatchdog.script, "watchdog", String(app.processIdentifier), String(helper.processIdentifier)]
        try watchdog.run()

        let deadline = Date().addingTimeInterval(8)
        while helper.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(helper.isRunning, "The watchdog must stop the helper after the app's process disappears")
        watchdog.waitUntilExit()
        XCTAssertEqual(watchdog.terminationStatus, 0)
    }

    func testWatchdogScriptExitsQuietlyWhenTheHelperStopsFirst() throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try helper.run()
        helper.waitUntilExit()

        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", ChildProcessWatchdog.script, "watchdog", String(ProcessInfo.processInfo.processIdentifier), String(helper.processIdentifier)]
        try watchdog.run()
        let deadline = Date().addingTimeInterval(5)
        while watchdog.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertFalse(watchdog.isRunning, "The watchdog must not linger once the helper is gone")
    }
}
