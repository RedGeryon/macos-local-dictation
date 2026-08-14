import Darwin
import XCTest
@testable import LocalDictation

final class SpeechServerManagerTests: XCTestCase {
    func testLaunchPlanUsesLocalhostAndExplicitModel() {
        let plan = SpeechServerLaunchPlan(
            executableURL: URL(fileURLWithPath: "/engine/nemo-speech"),
            modelURL: URL(fileURLWithPath: "/models/model.gguf"),
            host: "127.0.0.1",
            port: 17_866
        )

        XCTAssertEqual(plan.arguments, [
            "serve", "--asr-model", "/models/model.gguf",
            "--asr.streaming.rnnt_right_context", "1",
            "--endpointing",
            "--host", "127.0.0.1", "--port", "17866"
        ])
        XCTAssertEqual(plan.readyURL.absoluteString, "http://127.0.0.1:17866/ready")
    }

    @MainActor
    func testRealEngineStartsReadyAndStopsWithoutOrphan() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCAL_DICTATION_RUN_REAL_ENGINE_TESTS"] == "1",
              let enginePath = environment["LOCAL_DICTATION_ENGINE_PATH"],
              let modelPath = environment["LOCAL_DICTATION_MODEL_PATH"] else {
            throw XCTSkip("Set the real-engine environment variables to run the Metal lifecycle test.")
        }

        let configuration = AppConfiguration(
            engineURL: URL(fileURLWithPath: enginePath),
            modelURL: URL(fileURLWithPath: modelPath)
        )
        XCTAssertNil(configuration.validate())

        let manager = SpeechServerManager()
        try await manager.start(configuration: configuration)
        let pid = try XCTUnwrap(manager.processIdentifier)
        XCTAssertTrue(manager.isRunning)

        await manager.stop()
        XCTAssertFalse(manager.isRunning)
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "Speech engine process must not survive app shutdown")
    }

    @MainActor
    func testRealRealtimeWebSocketTranscribesPCMAndCommits() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCAL_DICTATION_RUN_REAL_ENGINE_TESTS"] == "1",
              let enginePath = environment["LOCAL_DICTATION_ENGINE_PATH"],
              let modelPath = environment["LOCAL_DICTATION_MODEL_PATH"],
              let audioPath = environment["LOCAL_DICTATION_TEST_AUDIO"] else {
            throw XCTSkip("Set the real-engine and test-audio environment variables.")
        }

        let manager = SpeechServerManager()
        let configuration = AppConfiguration(
            engineURL: URL(fileURLWithPath: enginePath),
            modelURL: URL(fileURLWithPath: modelPath)
        )
        try await manager.start(configuration: configuration)

        do {
            let realtimeURL = try XCTUnwrap(manager.realtimeURL)
            let pcm = try wavPCM16Data(at: URL(fileURLWithPath: audioPath))
            let connected = expectation(description: "WebSocket connected")
            let completed = expectation(description: "Final transcript received")
            var finalTranscript = ""

            let client = RealtimeTranscriptionClient()
            client.onConnectionChange = { value in
                if value { connected.fulfill() }
            }
            client.onFinal = { transcript in
                finalTranscript = transcript
                completed.fulfill()
            }
            client.onError = { error in
                XCTFail("Realtime client error: \(error)")
            }
            client.connect(to: realtimeURL, automaticPunctuation: true)
            await fulfillment(of: [connected], timeout: 5)

            client.beginUtterance()
            let batchSize = AudioCaptureService.transportBatchSamples * MemoryLayout<Int16>.size
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + batchSize, pcm.count)
                client.sendAudio(pcm.subdata(in: offset..<end))
                offset = end
            }
            client.finalize()
            await fulfillment(of: [completed], timeout: 30)
            client.disconnect()

            let words = finalTranscript
                .lowercased()
                .split(whereSeparator: { !$0.isLetter })
            XCTAssertEqual(words.last, "country", "The final spoken word must survive immediate commit: \(finalTranscript)")
        } catch {
            await manager.stop()
            throw error
        }
        await manager.stop()
    }

    @MainActor
    func testRealEndpointingProducesPauseBoundedTimestampedSegments() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCAL_DICTATION_RUN_REAL_ENGINE_TESTS"] == "1",
              let enginePath = environment["LOCAL_DICTATION_ENGINE_PATH"],
              let modelPath = environment["LOCAL_DICTATION_MODEL_PATH"],
              let audioPath = environment["LOCAL_DICTATION_TEST_AUDIO"] else {
            throw XCTSkip("Set the real-engine and test-audio environment variables.")
        }

        let manager = SpeechServerManager()
        let configuration = AppConfiguration(
            engineURL: URL(fileURLWithPath: enginePath),
            modelURL: URL(fileURLWithPath: modelPath)
        )
        try await manager.start(configuration: configuration)

        do {
            let connected = expectation(description: "Timestamped WebSocket connected")
            let completed = expectation(description: "Timestamped stream committed")
            let client = RealtimeTranscriptionClient()
            var segments: [RealtimeTranscriptSegment] = []
            client.onConnectionChange = { value in
                if value { connected.fulfill() }
            }
            client.onSegment = { segment in segments.append(segment) }
            client.onFinal = { _ in completed.fulfill() }
            client.onError = { error in XCTFail("Timestamped realtime client error: \(error)") }
            client.connect(
                to: try XCTUnwrap(manager.realtimeURL),
                automaticPunctuation: true,
                wordTimestamps: true,
                endpointingMilliseconds: 800
            )
            await fulfillment(of: [connected], timeout: 5)

            client.beginUtterance()
            let pcm = try wavPCM16Data(at: URL(fileURLWithPath: audioPath))
            let silence = Data(count: 16_000 * MemoryLayout<Int16>.size)
            let audio = pcm + silence + pcm
            let batchSize = AudioCaptureService.transportBatchSamples * MemoryLayout<Int16>.size
            var offset = 0
            while offset < audio.count {
                let end = min(offset + batchSize, audio.count)
                client.sendAudio(audio.subdata(in: offset..<end))
                offset = end
            }
            client.finalize()
            await fulfillment(of: [completed], timeout: 45)
            client.disconnect()

            XCTAssertGreaterThanOrEqual(segments.count, 2, "The inserted silence must close a turn")
            XCTAssertTrue(segments.allSatisfy { $0.endTime >= $0.startTime })
            XCTAssertEqual(
                segments.map(\.startTime),
                segments.map(\.startTime).sorted(),
                "Word timestamps must remain on the stream's absolute audio clock"
            )
        } catch {
            await manager.stop()
            throw error
        }
        await manager.stop()
    }

    @MainActor
    func testRealEngineTranscribesMicrophoneAndSpeakerStreamsConcurrently() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCAL_DICTATION_RUN_REAL_ENGINE_TESTS"] == "1",
              let enginePath = environment["LOCAL_DICTATION_ENGINE_PATH"],
              let modelPath = environment["LOCAL_DICTATION_MODEL_PATH"],
              let audioPath = environment["LOCAL_DICTATION_TEST_AUDIO"] else {
            throw XCTSkip("Set the real-engine and test-audio environment variables.")
        }

        let manager = SpeechServerManager()
        let configuration = AppConfiguration(
            engineURL: URL(fileURLWithPath: enginePath),
            modelURL: URL(fileURLWithPath: modelPath)
        )
        try await manager.start(configuration: configuration)

        do {
            let realtimeURL = try XCTUnwrap(manager.realtimeURL)
            let pcm = try wavPCM16Data(at: URL(fileURLWithPath: audioPath))
            let connected = expectation(description: "Two WebSockets connected")
            connected.expectedFulfillmentCount = 2
            let completed = expectation(description: "Two final transcripts received")
            completed.expectedFulfillmentCount = 2
            var finals: [String] = []
            let clients = [RealtimeTranscriptionClient(), RealtimeTranscriptionClient()]

            for client in clients {
                client.onConnectionChange = { value in
                    if value { connected.fulfill() }
                }
                client.onFinal = { transcript in
                    finals.append(transcript)
                    completed.fulfill()
                }
                client.onError = { error in
                    XCTFail("Concurrent realtime client error: \(error)")
                }
                client.connect(to: realtimeURL, automaticPunctuation: true)
            }
            await fulfillment(of: [connected], timeout: 5)

            clients.forEach { $0.beginUtterance() }
            let batchSize = AudioCaptureService.transportBatchSamples * MemoryLayout<Int16>.size
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + batchSize, pcm.count)
                let batch = pcm.subdata(in: offset..<end)
                clients.forEach { $0.sendAudio(batch) }
                offset = end
            }
            clients.forEach { $0.finalize() }
            await fulfillment(of: [completed], timeout: 45)
            clients.forEach { $0.disconnect() }

            XCTAssertEqual(finals.count, 2)
            for transcript in finals {
                let words = transcript.lowercased().split(whereSeparator: { !$0.isLetter })
                XCTAssertEqual(words.last, "country", "Both audio channels must retain the final word: \(transcript)")
            }
        } catch {
            await manager.stop()
            throw error
        }
        await manager.stop()
    }

    @MainActor
    func testRealEmptyConversationChannelFinalizesPromptly() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCAL_DICTATION_RUN_REAL_ENGINE_TESTS"] == "1",
              let enginePath = environment["LOCAL_DICTATION_ENGINE_PATH"],
              let modelPath = environment["LOCAL_DICTATION_MODEL_PATH"] else {
            throw XCTSkip("Set the real-engine environment variables.")
        }

        let manager = SpeechServerManager()
        let configuration = AppConfiguration(
            engineURL: URL(fileURLWithPath: enginePath),
            modelURL: URL(fileURLWithPath: modelPath)
        )
        try await manager.start(configuration: configuration)

        do {
            let connected = expectation(description: "Quiet channel connected")
            let completed = expectation(description: "Quiet channel finalized")
            var finalTranscript: String?
            let client = RealtimeTranscriptionClient()
            client.onConnectionChange = { value in
                if value { connected.fulfill() }
            }
            client.onFinal = { transcript in
                finalTranscript = transcript
                completed.fulfill()
            }
            client.onError = { error in XCTFail("Quiet channel error: \(error)") }
            client.connect(to: try XCTUnwrap(manager.realtimeURL), automaticPunctuation: true)
            await fulfillment(of: [connected], timeout: 5)
            client.beginUtterance()
            client.finalize()
            await fulfillment(of: [completed], timeout: 10)
            XCTAssertEqual(finalTranscript, "")
            client.disconnect()
        } catch {
            await manager.stop()
            throw error
        }
        await manager.stop()
    }

    private func wavPCM16Data(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let size = data[(offset + 4)..<(offset + 8)].withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            let start = offset + 8
            let end = start + size
            guard end <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            if chunkID == "data" { return data.subdata(in: start..<end) }
            offset = end + (size % 2)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
