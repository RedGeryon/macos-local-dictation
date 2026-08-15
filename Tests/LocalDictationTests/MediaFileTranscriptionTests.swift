import Darwin
import XCTest
@testable import LocalDictation

final class MediaFileTranscriptionTests: XCTestCase {
    func testEstimateIsConservativeAndLearnsFromCompletedWork() throws {
        let suiteName = "LocalDictationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var estimator = MediaFileTranscriptionEstimator(
            modelVariant: .multilingual,
            defaults: defaults
        )

        XCTAssertEqual(estimator.estimatedSeconds(for: 600), 26, accuracy: 0.001)
        estimator.record(duration: 600, elapsed: 8)

        let learned = MediaFileTranscriptionEstimator(
            modelVariant: .multilingual,
            defaults: defaults
        )
        XCTAssertLessThan(learned.estimatedSeconds(for: 600), 26)
        XCTAssertGreaterThanOrEqual(learned.estimatedSeconds(for: 600), 5)
    }

    func testWAVHeaderDescribesMono16KHzPCM() throws {
        let header = try MediaFileTranscriptionService.wavHeader(pcmByteCount: 3_200)
        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(String(data: header[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: header[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(littleEndianUInt32(header, at: 24), 16_000)
        XCTAssertEqual(littleEndianUInt32(header, at: 28), 32_000)
        XCTAssertEqual(littleEndianUInt16(header, at: 22), 1)
        XCTAssertEqual(littleEndianUInt16(header, at: 34), 16)
        XCTAssertEqual(littleEndianUInt32(header, at: 40), 3_200)
    }

    func testMediaInspectionAndOnePassMultipartConversion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wavURL = directory.appendingPathComponent("fixture.wav")
        let pcm = Data(count: 3_200)
        try (MediaFileTranscriptionService.wavHeader(pcmByteCount: pcm.count) + pcm)
            .write(to: wavURL)

        let information = try await MediaFileTranscriptionService().inspect(wavURL)
        XCTAssertEqual(information.formatLabel, "WAV")
        XCTAssertFalse(information.containsVideo)
        XCTAssertEqual(information.duration, 0.1, accuracy: 0.01)

        let upload = try await MediaFileTranscriptionService.makeMultipartUpload(
            information: information,
            language: .englishUS,
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: upload.fileURL) }
        let body = try Data(contentsOf: upload.fileURL)
        XCTAssertNotNil(body.range(of: Data("Content-Type: audio/wav".utf8)))
        XCTAssertNotNil(body.range(of: Data("RIFF".utf8)))
        XCTAssertNotNil(body.range(of: Data("name=\"language\"".utf8)))
        XCTAssertNotNil(body.range(of: Data("en-US".utf8)))
        XCTAssertTrue(body.suffix(4).elementsEqual(Data("--\r\n".utf8)))
    }

    @MainActor
    func testRealWarmServerTranscribesSelectedMediaFormat() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCAL_DICTATION_RUN_REAL_ENGINE_TESTS"] == "1",
              let enginePath = environment["LOCAL_DICTATION_ENGINE_PATH"],
              let modelPath = environment["LOCAL_DICTATION_MODEL_PATH"],
              let mediaPath = environment["LOCAL_DICTATION_TEST_MEDIA"] else {
            throw XCTSkip("Set the real-engine paths and LOCAL_DICTATION_TEST_MEDIA to run the file workflow test.")
        }

        var isDirectory: ObjCBool = false
        let selectedURL = URL(fileURLWithPath: mediaPath)
        let mediaURLs: [URL]
        if FileManager.default.fileExists(atPath: mediaPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            mediaURLs = try FileManager.default.contentsOfDirectory(
                at: selectedURL,
                includingPropertiesForKeys: nil
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            mediaURLs = [selectedURL]
        }
        XCTAssertFalse(mediaURLs.isEmpty)

        let manager = SpeechServerManager()
        let configuration = AppConfiguration(
            engineURL: URL(fileURLWithPath: enginePath),
            modelURL: URL(fileURLWithPath: modelPath),
            recognitionLanguage: .englishUS
        )
        try await manager.start(configuration: configuration)
        do {
            let service = MediaFileTranscriptionService()
            for mediaURL in mediaURLs {
                let information = try await service.inspect(mediaURL)
                let transcript = try await service.transcribe(
                    information,
                    endpoint: try XCTUnwrap(manager.fileTranscriptionURL),
                    language: configuration.recognitionLanguage,
                    progress: { _ in }
                )
                XCTAssertFalse(
                    transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Expected a transcript for \(mediaURL.lastPathComponent)"
                )
            }
        } catch {
            await manager.stop()
            throw error
        }
        let processIdentifier = try XCTUnwrap(manager.processIdentifier)
        await manager.stop()
        XCTAssertNotEqual(Darwin.kill(processIdentifier, 0), 0)
    }

    private func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data[offset..<(offset + 2)].withUnsafeBytes {
            UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))
        }
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }
}
