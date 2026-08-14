import XCTest
@testable import LocalDictation

final class RealtimeTranscriptionClientTests: XCTestCase {
    func testCompletedEventUsesFirstAndLastWordTimestamps() {
        let segment = RealtimeTranscriptionClient.transcriptSegment(
            from: [
                "audio_processed": 9.5,
                "words": [
                    ["word": "hello", "start": 3.25, "end": 3.6],
                    ["word": "there", "start": 3.7, "end": 4.1]
                ]
            ],
            transcript: "hello there",
            fallbackStartTime: 2
        )

        XCTAssertEqual(segment.text, "hello there")
        XCTAssertEqual(segment.startTime, 3.25)
        XCTAssertEqual(segment.endTime, 4.1)
    }

    func testCompletedEventFallsBackToProcessedAudioClock() {
        let segment = RealtimeTranscriptionClient.transcriptSegment(
            from: ["audio_processed": 8.0],
            transcript: "fallback",
            fallbackStartTime: 5.0
        )

        XCTAssertEqual(segment.startTime, 5.0)
        XCTAssertEqual(segment.endTime, 8.0)
    }
}
