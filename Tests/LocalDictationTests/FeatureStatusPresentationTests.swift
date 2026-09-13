import AppKit
import XCTest
@testable import LocalDictation

final class FeatureStatusPresentationTests: XCTestCase {
    private func speech(
        _ state: AppState,
        _ engine: LocalFeatureRuntimeStatus = .ready,
        enabled: Bool = true
    ) -> FeatureStatusPresentation {
        FeatureStatusPresentation.speechToText(state: state, engine: engine, enabled: enabled)
    }

    private func readAloud(
        _ state: TextToSpeechState,
        _ engine: LocalFeatureRuntimeStatus = .ready,
        enabled: Bool = true
    ) -> FeatureStatusPresentation {
        FeatureStatusPresentation.textToSpeech(state: state, engine: engine, enabled: enabled)
    }

    // MARK: - Tone styling

    func testToneColorsAndSymbols() {
        let cases: [(FeatureStatusTone, NSColor, String)] = [
            (.off, .tertiaryLabelColor, "circle.dotted"),
            (.idle, .secondaryLabelColor, "circle.fill"),
            (.ready, .systemGreen, "circle.fill"),
            (.busy, .systemBlue, "circle.fill"),
            (.recording, .systemRed, "circle.fill"),
            (.attention, .systemOrange, "exclamationmark.circle.fill")
        ]
        for (tone, color, symbol) in cases {
            let status = FeatureStatusPresentation(label: "x", tone: tone)
            XCTAssertEqual(status.color, color, "color for \(tone)")
            XCTAssertEqual(status.symbolName, symbol, "symbol for \(tone)")
        }
    }

    // MARK: - Speech to Text

    func testSpeechToTextDisabledIsOff() {
        let status = speech(.ready, .ready, enabled: false)
        XCTAssertEqual(status.label, "Disabled")
        XCTAssertEqual(status.tone, .off)
        XCTAssertNil(status.detail)
    }

    func testSpeechToTextRecordingStates() {
        XCTAssertEqual(speech(.recording(.pushToTalk)).label, "Listening")
        XCTAssertEqual(speech(.recording(.pushToTalk)).tone, .recording)
        XCTAssertEqual(speech(.recording(.handsFree)).tone, .recording)
        XCTAssertEqual(speech(.recordingConversation).label, "Recording conversation")
        XCTAssertEqual(speech(.recordingConversation).tone, .recording)
    }

    func testSpeechToTextBusyStates() {
        let busy: [AppState] = [
            .transcribingFile, .inspectingMedia, .finalizing,
            .inserting, .savingConversation, .startingConversation
        ]
        for state in busy {
            let status = speech(state)
            XCTAssertEqual(status.tone, .busy, "tone for \(state)")
            XCTAssertEqual(status.label, state.label, "label for \(state)")
        }
    }

    func testSpeechToTextAttentionStates() {
        XCTAssertEqual(speech(.installationRequired).tone, .attention)
        XCTAssertEqual(speech(.installationRequired).label, AppState.installationRequired.label)
        XCTAssertEqual(speech(.permissionRequired).tone, .attention)

        let configuration = speech(.configurationRequired(.modelMissing))
        XCTAssertEqual(configuration.tone, .attention)
        XCTAssertEqual(configuration.label, "Speech model required")
        XCTAssertEqual(configuration.detail, "Speech model required")

        let unavailable = speech(.serverUnavailable("port busy"))
        XCTAssertEqual(unavailable.tone, .attention)
        XCTAssertEqual(unavailable.label, "Speech engine unavailable")
        XCTAssertEqual(unavailable.detail, "port busy")

        let failure = speech(.error("boom"))
        XCTAssertEqual(failure.tone, .attention)
        XCTAssertEqual(failure.label, "Needs attention")
        XCTAssertEqual(failure.detail, "boom")
    }

    func testSpeechToTextFallsBackToEngineStatus() {
        XCTAssertEqual(speech(.starting, .loading).label, "Loading…")
        XCTAssertEqual(speech(.starting, .loading).tone, .busy)

        let failed = speech(.starting, .error("no engine"))
        XCTAssertEqual(failed.label, "Needs attention")
        XCTAssertEqual(failed.detail, "no engine")
        XCTAssertEqual(failed.tone, .attention)

        XCTAssertEqual(speech(.starting, .notLoaded).label, "Not loaded")
        XCTAssertEqual(speech(.starting, .notLoaded).tone, .idle)

        XCTAssertEqual(speech(.starting, .disabled).label, "Disabled")
        XCTAssertEqual(speech(.starting, .disabled).tone, .off)

        XCTAssertEqual(speech(.ready, .ready).label, "Ready")
        XCTAssertEqual(speech(.ready, .ready).tone, .ready)
    }

    // MARK: - Text to Speech

    func testTextToSpeechDisabledIsOff() {
        let status = readAloud(.ready, .ready, enabled: false)
        XCTAssertEqual(status.label, "Disabled")
        XCTAssertEqual(status.tone, .off)
    }

    func testTextToSpeechActiveStates() {
        XCTAssertEqual(readAloud(.speaking(paused: false)).label, "Reading…")
        XCTAssertEqual(readAloud(.speaking(paused: false)).tone, .busy)
        XCTAssertEqual(readAloud(.speaking(paused: true)).label, "Paused")
        XCTAssertEqual(readAloud(.speaking(paused: true)).tone, .busy)
        XCTAssertEqual(readAloud(.generating).label, "Generating audio…")
        XCTAssertEqual(readAloud(.starting).label, "Preparing…")
        XCTAssertEqual(readAloud(.canceling).label, "Canceling…")
        for state: TextToSpeechState in [.generating, .starting, .canceling] {
            XCTAssertEqual(readAloud(state).tone, .busy, "tone for \(state)")
        }
    }

    func testTextToSpeechProblemStates() {
        let unavailable = readAloud(.unavailable("install the runtime"))
        XCTAssertEqual(unavailable.label, "Needs setup")
        XCTAssertEqual(unavailable.detail, "install the runtime")
        XCTAssertEqual(unavailable.tone, .attention)

        let failure = readAloud(.error("crashed"))
        XCTAssertEqual(failure.label, "Needs attention")
        XCTAssertEqual(failure.detail, "crashed")
        XCTAssertEqual(failure.tone, .attention)
    }

    func testTextToSpeechFallsBackToEngineStatus() {
        XCTAssertEqual(readAloud(.idle, .loading).label, "Loading…")
        XCTAssertEqual(readAloud(.idle, .loading).tone, .busy)

        let failed = readAloud(.idle, .error("missing model"))
        XCTAssertEqual(failed.label, "Needs attention")
        XCTAssertEqual(failed.detail, "missing model")
        XCTAssertEqual(failed.tone, .attention)

        XCTAssertEqual(readAloud(.idle, .notLoaded).label, "Not loaded")
        XCTAssertEqual(readAloud(.idle, .notLoaded).tone, .idle)

        XCTAssertEqual(readAloud(.idle, .disabled).label, "Disabled")
        XCTAssertEqual(readAloud(.idle, .disabled).tone, .off)

        XCTAssertEqual(readAloud(.ready, .ready).label, "Ready")
        XCTAssertEqual(readAloud(.ready, .ready).tone, .ready)
    }

    // MARK: - Menu bar tint

    func testMenuBarTintPriority() {
        func tint(_ first: FeatureStatusTone, _ second: FeatureStatusTone) -> NSColor? {
            FeatureStatusPresentation.menuBarTint(
                speechToText: FeatureStatusPresentation(label: "a", tone: first),
                textToSpeech: FeatureStatusPresentation(label: "b", tone: second)
            )
        }

        XCTAssertEqual(tint(.recording, .attention), .systemRed)
        XCTAssertEqual(tint(.attention, .recording), .systemRed)
        XCTAssertEqual(tint(.attention, .busy), .systemOrange)
        XCTAssertEqual(tint(.ready, .attention), .systemOrange)
        XCTAssertEqual(tint(.busy, .ready), .systemBlue)
        XCTAssertEqual(tint(.ready, .off), .systemGreen)
        XCTAssertEqual(tint(.idle, .ready), .systemGreen)
        XCTAssertNil(tint(.off, .off))
        XCTAssertNil(tint(.idle, .off))
        XCTAssertNil(tint(.idle, .idle))
    }
}
