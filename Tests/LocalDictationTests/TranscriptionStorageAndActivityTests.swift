import Foundation
import XCTest
@testable import LocalDictation

final class TranscriptionStorageAndActivityTests: XCTestCase {
    func testDailyFoldersUseLocalDayAndSortChronologically() throws {
        let root = URL(fileURLWithPath: "/tmp/transcripts", isDirectory: true)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let pacific = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let previous = TranscriptStorage.dailyDirectory(in: root, at: date, timeZone: pacific)
        let next = TranscriptStorage.dailyDirectory(in: root, at: date, timeZone: utc)
        XCTAssertEqual(previous.lastPathComponent, "2025-12-31")
        XCTAssertEqual(next.lastPathComponent, "2026-01-01")
        XCTAssertEqual(previous.deletingLastPathComponent(), root)
        XCTAssertLessThan(previous.lastPathComponent, next.lastPathComponent)
        XCTAssertEqual(next, TranscriptStorage.dailyDirectory(in: root, at: date.addingTimeInterval(3600), timeZone: utc))
    }

    func testActivityIsHeldAcrossTranscriptionStagesAndReleasedOnCompletion() {
        var starts = 0
        var ends = 0
        let activity = TranscriptionActivity(begin: { starts += 1; return NSObject() }, end: { _ in ends += 1 })
        for state in [AppState.inspectingMedia, .transcribingFile, .finalizing, .ready] {
            activity.setActive(state.keepsAwakeForTranscription)
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
        activity.setActive(false)
        XCTAssertEqual(ends, 1)
        for terminal in [AppState.ready, .error("failed"), .serverUnavailable("stopped")] {
            activity.setActive(AppState.recordingConversation.keepsAwakeForTranscription)
            activity.setActive(AppState.savingConversation.keepsAwakeForTranscription)
            activity.setActive(terminal.keepsAwakeForTranscription)
        }
        XCTAssertEqual(starts, 4)
        XCTAssertEqual(ends, 4)
    }

    func testActivityReleasesWhenOwnerIsDestroyed() {
        var ends = 0
        var activity: TranscriptionActivity? = TranscriptionActivity(begin: { NSObject() }, end: { _ in ends += 1 })
        activity?.setActive(true)
        activity = nil
        XCTAssertEqual(ends, 1)
    }
}
