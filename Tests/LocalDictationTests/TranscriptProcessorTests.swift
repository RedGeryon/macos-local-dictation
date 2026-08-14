import XCTest
@testable import LocalDictation

final class TranscriptProcessorTests: XCTestCase {
    func testNormalizesCommandsDisfluenciesAndBoundaries() {
        let result = TranscriptProcessor.process(
            "Um this this works, press enter.",
            context: InsertionContext(textBeforeCursor: "I think", textAfterCursor: ""),
            removeFillers: true
        )

        XCTAssertEqual(result.text, " this works")
        XCTAssertTrue(result.shouldPressReturn)
    }

    func testNewParagraphBecomesTwoNewlines() {
        let result = TranscriptProcessor.process("First thought new paragraph Second thought")
        XCTAssertEqual(result.text, "First thought\n\nSecond thought")
        XCTAssertFalse(result.shouldPressReturn)
    }

    func testDoesNotAddSpaceBeforeClosingPunctuation() {
        let result = TranscriptProcessor.process(
            "Done.",
            context: InsertionContext(textBeforeCursor: "(", textAfterCursor: ")")
        )
        XCTAssertEqual(result.text, "Done.")
    }
}
