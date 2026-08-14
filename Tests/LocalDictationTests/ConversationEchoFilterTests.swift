import XCTest
@testable import LocalDictation

final class ConversationEchoFilterTests: XCTestCase {
    func testDropsAnExactSystemAudioDuplicate() {
        XCTAssertNil(ConversationEchoFilter.removingEcho(
            from: "Pause the video after you have heard the sentence twice.",
            matching: "Pause the video after you have heard the sentence twice."
        ))
    }

    func testPreservesUserSpeechBeforeAnEchoedTail() {
        XCTAssertEqual(
            ConversationEchoFilter.removingEcho(
                from: "He won't be able to do it. Is that what he's asking? Pause the video after you have heard the sentence twice and write down what you've heard.",
                matching: "Pause the video after you have heard the sentence twice and write down what you've heard."
            ),
            "He won't be able to do it. Is that what he's asking?"
        )
    }

    func testToleratesNoisyMicrophoneWordDifferences() {
        XCTAssertNil(ConversationEchoFilter.removingEcho(
            from: "Pause the videos after you've heard this sentence twice and write what you heard.",
            matching: "Pause the video after you have heard the sentence twice and write down what you've heard."
        ))
    }

    func testRetainsUnrelatedMicrophoneSpeech() {
        let microphone = "I think we should schedule the design review for tomorrow morning."
        XCTAssertEqual(
            ConversationEchoFilter.removingEcho(
                from: microphone,
                matching: "Pause the video after you have heard the sentence twice."
            ),
            microphone
        )
    }

    func testRetainsShortCommonPhrases() {
        XCTAssertEqual(
            ConversationEchoFilter.removingEcho(from: "Yes, please.", matching: "Yes, please."),
            "Yes, please."
        )
    }

    func testDropsMicrophoneEchoWhenCleanSpeakerSegmentIsMuchLonger() {
        XCTAssertNil(ConversationEchoFilter.removingEcho(
            from: "A record must be made of the healthcare professional's analysis.",
            matching: "Every time a patient is examined or diagnostic tests are reviewed, a record must be made of the healthcare professional's analysis. That report becomes a part of the patient's medical record, a vital chapter in an ongoing story."
        ))
    }

    func testPreservesUserWordsBesideAShorterEchoFromLongSpeakerSegment() {
        XCTAssertEqual(
            ConversationEchoFilter.removingEcho(
                from: "I agree with that conclusion. A record must be made of the healthcare professional's analysis.",
                matching: "Every time a patient is examined or diagnostic tests are reviewed, a record must be made of the healthcare professional's analysis. That report becomes a part of the patient's medical record."
            ),
            "I agree with that conclusion."
        )
    }

    func testDoesNotRemoveFiveWordOverlap() {
        let microphone = "That is a good point."
        XCTAssertEqual(
            ConversationEchoFilter.removingEcho(
                from: microphone,
                matching: "I think that is a good point about the design."
            ),
            microphone
        )
    }
}
