import Foundation
import XCTest
@testable import LocalDictation

final class ConversationTranscriptWriterTests: XCTestCase {
    func testTranscriptLineLabelsSpeakerAndFormatsElapsedTime() {
        XCTAssertEqual(
            ConversationTranscriptFormatter.line(
                elapsed: 65,
                speaker: .you,
                text: "  hello   there  "
            ),
            "[01:05] You: hello there\n\n"
        )
        XCTAssertEqual(
            ConversationTranscriptFormatter.line(
                elapsed: 3_661,
                speaker: .speaker,
                text: "Welcome back."
            ),
            "[01:01:01] Speaker: Welcome back.\n\n"
        )
    }

    func testHeaderExplainsBothLocalAudioSources() {
        let header = ConversationTranscriptFormatter.header(
            startedAt: Date(timeIntervalSince1970: 0),
            microphoneName: "Test Mic"
        )
        XCTAssertTrue(header.contains("Microphone: Test Mic"))
        XCTAssertTrue(header.contains("Speaker audio: Mac system audio"))
    }

    func testFinalDocumentOrdersTurnsByAudioTimeInsteadOfDecoderArrival() {
        let entries = [
            ConversationTranscriptEntry(
                speaker: .speaker,
                text: "third",
                startTime: 8,
                endTime: 9,
                sequence: 0
            ),
            ConversationTranscriptEntry(
                speaker: .you,
                text: "first",
                startTime: 1,
                endTime: 2,
                sequence: 1
            ),
            ConversationTranscriptEntry(
                speaker: .speaker,
                text: "second",
                startTime: 4,
                endTime: 5,
                sequence: 2
            )
        ]

        let document = ConversationTranscriptFormatter.document(
            startedAt: Date(timeIntervalSince1970: 0),
            microphoneName: "Test Mic",
            entries: entries,
            endedAt: Date(timeIntervalSince1970: 10)
        )
        let first = try! XCTUnwrap(document.range(of: "You: first"))
        let second = try! XCTUnwrap(document.range(of: "Speaker: second"))
        let third = try! XCTUnwrap(document.range(of: "Speaker: third"))

        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertLessThan(second.lowerBound, third.lowerBound)
    }
}
