import AVFoundation
import XCTest
@testable import LocalDictation

/// These checks deliberately use AVAudioEngine instead of mocking playback.
/// They are opt-in because headless macOS runners may not have an audio route.
final class TextToSpeechPlaybackTests: XCTestCase {
    @MainActor
    func testPlays24kHzMonoPCMAndDrains() async throws {
        try requirePlaybackEnvironment()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let controller = TextToSpeechPlaybackController()
        defer { controller.stop() }
        let played = expectation(description: "24 kHz PCM buffer played")
        let generation = controller.begin()

        do {
            try controller.enqueue(url: try makePCMFixture(in: temporaryDirectory, named: "single", duration: 0.25), generation: generation) {
                played.fulfill()
            }
        } catch TextToSpeechError.playbackFailed {
            throw XCTSkip("No native audio output route is available for AVAudioEngine playback.")
        }
        controller.producerDidComplete(generation: generation)
        try await controller.waitUntilDrained(generation: generation)
        await fulfillment(of: [played], timeout: 3)
    }

    @MainActor
    func testQueuedChunksPlayAndAcknowledgeInOrder() async throws {
        try requirePlaybackEnvironment()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let controller = TextToSpeechPlaybackController()
        defer { controller.stop() }
        let generation = controller.begin()
        var acknowledged: [Int] = []
        let callbacks = expectation(description: "all queued chunks played")
        callbacks.expectedFulfillmentCount = 3

        do {
            for index in 0..<3 {
                try controller.enqueue(url: try makePCMFixture(in: temporaryDirectory, named: "queue-\(index)", duration: 0.12), generation: generation) {
                    acknowledged.append(index)
                    callbacks.fulfill()
                }
            }
        } catch TextToSpeechError.playbackFailed {
            throw XCTSkip("No native audio output route is available for AVAudioEngine playback.")
        }
        controller.producerDidComplete(generation: generation)
        try await controller.waitUntilDrained(generation: generation)
        await fulfillment(of: [callbacks], timeout: 4)
        XCTAssertEqual(acknowledged, [0, 1, 2])
    }

    @MainActor
    func testPauseResumeKeepsQueuedAudio() async throws {
        try requirePlaybackEnvironment()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let controller = TextToSpeechPlaybackController()
        defer { controller.stop() }
        let generation = controller.begin()
        var acknowledgements = 0
        let played = expectation(description: "paused buffer resumes and plays")

        do {
            try controller.enqueue(url: try makePCMFixture(in: temporaryDirectory, named: "pause", duration: 0.6), generation: generation) {
                acknowledgements += 1
                played.fulfill()
            }
        } catch TextToSpeechError.playbackFailed {
            throw XCTSkip("No native audio output route is available for AVAudioEngine playback.")
        }
        controller.pause()
        XCTAssertTrue(controller.isPaused)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(acknowledgements, 0, "A paused node must retain its queued buffer.")

        controller.resume()
        XCTAssertFalse(controller.isPaused)
        controller.producerDidComplete(generation: generation)
        try await controller.waitUntilDrained(generation: generation)
        await fulfillment(of: [played], timeout: 3)
        XCTAssertEqual(acknowledgements, 1)
    }

    @MainActor
    func testStopThenNewGenerationIgnoresLateOldCompletion() async throws {
        try requirePlaybackEnvironment()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let controller = TextToSpeechPlaybackController()
        defer { controller.stop() }
        var oldCallbacks = 0
        var newCallbacks = 0
        let newPlayed = expectation(description: "new generation played")
        let oldGeneration = controller.begin()

        do {
            try controller.enqueue(url: try makePCMFixture(in: temporaryDirectory, named: "old", duration: 1.0), generation: oldGeneration) {
                oldCallbacks += 1
            }
        } catch TextToSpeechError.playbackFailed {
            throw XCTSkip("No native audio output route is available for AVAudioEngine playback.")
        }
        controller.stop()

        let newGeneration = controller.begin()
        try controller.enqueue(url: try makePCMFixture(in: temporaryDirectory, named: "new", duration: 0.2), generation: newGeneration) {
            newCallbacks += 1
            newPlayed.fulfill()
        }
        controller.producerDidComplete(generation: newGeneration)
        try await controller.waitUntilDrained(generation: newGeneration)
        await fulfillment(of: [newPlayed], timeout: 3)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(oldCallbacks, 0, "A completion from the stopped generation must not acknowledge a new job.")
        XCTAssertEqual(newCallbacks, 1)
    }

    private func requirePlaybackEnvironment() throws {
        guard ProcessInfo.processInfo.environment["LOCAL_DICTATION_TEST_TTS_PLAYBACK"] == "1" else {
            throw XCTSkip("Set LOCAL_DICTATION_TEST_TTS_PLAYBACK=1 to run native AVAudioEngine playback checks.")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictation-TTSPlayback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePCMFixture(in directory: URL, named name: String, duration: Double) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let frames = AVAudioFrameCount((duration * format.sampleRate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?[0] else {
            throw TextToSpeechError.playbackFailed
        }
        // A quiet non-zero sample guards against formats that accept an empty
        // buffer but do not exercise AVAudioPlayerNode's PCM path.
        for index in 0..<Int(frames) {
            samples[index] = index.isMultiple(of: 96) ? 0.01 : 0
        }
        let url = directory.appendingPathComponent(name).appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
