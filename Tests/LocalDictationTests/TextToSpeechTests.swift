import XCTest
@testable import LocalDictation

final class TextToSpeechTests: XCTestCase {
    func testTTSCatalogListsVerifiedWeightsWithoutRuntimeAndRejectsPartialOrWrongPins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = models.appendingPathComponent("qwen3-tts-1.7b-customvoice-8bit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("speech_tokenizer"), withIntermediateDirectories: true)
        try Data("{\"repository\":\"mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit\",\"revision\":\"41d3337e8b7f2843a75841595fc14e4b9a7a4b96\"}".utf8).write(to: directory.appendingPathComponent(".local-dictation-complete.json"))
        for name in ["config.json", "tokenizer_config.json", "vocab.json", "merges.txt", "weights.safetensors"] { try Data("x".utf8).write(to: directory.appendingPathComponent(name)) }
        let catalog = TextToSpeechModelCatalog.installedFamilies(modelsDirectory: models, runtimeDirectory: runtime)
        let eight = try XCTUnwrap(catalog.first { $0.model == .eightBit })
        XCTAssertTrue(eight.customVoiceInstalled)
        XCTAssertFalse(eight.runtimeInstalled)
        XCTAssertFalse(catalog.first { $0.model == .bf16 }!.customVoiceInstalled)

        // A completion marker alone is not enough: it must have the exact
        // pinned repository and every required asset.
        let bf16 = models.appendingPathComponent("qwen3-tts-1.7b-customvoice-bf16", isDirectory: true)
        try FileManager.default.createDirectory(at: bf16.appendingPathComponent("speech_tokenizer"), withIntermediateDirectories: true)
        try Data("{\"repository\":\"wrong/repository\",\"revision\":\"52f4770fd9726457eae3d3b6aa92047a25a10776\"}".utf8).write(to: bf16.appendingPathComponent(".local-dictation-complete.json"))
        for name in ["config.json", "tokenizer_config.json", "vocab.json", "merges.txt", "weights.safetensors"] { try Data("x".utf8).write(to: bf16.appendingPathComponent(name)) }
        XCTAssertFalse(TextToSpeechModelCatalog.installedFamilies(modelsDirectory: models, runtimeDirectory: runtime).first { $0.model == .bf16 }!.customVoiceInstalled)

        try Data("{\"repository\":\"mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16\",\"revision\":\"52f4770fd9726457eae3d3b6aa92047a25a10776\"}".utf8).write(to: bf16.appendingPathComponent(".local-dictation-complete.json"))
        try FileManager.default.removeItem(at: bf16.appendingPathComponent("merges.txt"))
        XCTAssertFalse(TextToSpeechModelCatalog.installedFamilies(modelsDirectory: models, runtimeDirectory: runtime).first { $0.model == .bf16 }!.customVoiceInstalled)
    }

    func testCompletedCustomVoiceSelectionPreservesValidCurrentFamily() {
        let validBF16 = InstalledTextToSpeechFamily(model: .bf16, runtimeInstalled: false, customVoiceInstalled: true, voiceDesignInstalled: false, baseInstalled: false)
        XCTAssertEqual(TextToSpeechModelCatalog.selectionAfterCompletedDownload(component: .customVoice, downloaded: .eightBit, current: .bf16, installed: [validBF16]), .bf16)
        XCTAssertEqual(TextToSpeechModelCatalog.selectionAfterCompletedDownload(component: .customVoice, downloaded: .eightBit, current: .bf16, installed: []), .eightBit)
    }
    func testTTSComponentDownloadsUseTheSelectedPrecisionWithoutLoading() {
        XCTAssertEqual(TextToSpeechModelComponent.customVoice.downloadArgument(for: .bf16), "custom")
        XCTAssertEqual(TextToSpeechModelComponent.customVoice.downloadArgument(for: .eightBit), "custom8")
        XCTAssertEqual(TextToSpeechModelComponent.voiceDesign.downloadArgument(for: .eightBit), "design8")
        XCTAssertEqual(TextToSpeechModelComponent.base.downloadArgument(for: .bf16), "base")
        XCTAssertFalse(TextToSpeechInstallState.idle.isActive)
        XCTAssertTrue(TextToSpeechInstallState.downloading(.customVoice, .eightBit).isActive)
    }
    private final class TTSURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responseStatus = 200
        nonisolated(unsafe) static var responseBody = Data()
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.responseStatus,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/x-ndjson"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func writeFastReadyWorker() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictation-TTS-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launcher = directory.appendingPathComponent("fast-ready-worker.sh")
        let source = """
        #!/bin/bash
        exec /usr/bin/python3 - <<'PY'
        import json
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/v1/voices':
                    body = json.dumps([{'id':'ryan','name':'Ryan','description':'test'}]).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_error(404)
            def log_message(self, format, *args):
                pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        print(json.dumps({'ready': True, 'port': server.server_port, 'protocol': 1}), flush=True)
        server.serve_forever()
        PY
        """
        try source.write(to: launcher, atomically: true, encoding: .utf8)
        return launcher
    }

    @MainActor
    func testServerManagerAcceptsAnImmediateReadyLineAndLoadsVoices() async throws {
        let launcher = try writeFastReadyWorker()
        defer { try? FileManager.default.removeItem(at: launcher.deletingLastPathComponent()) }
        let manager = TextToSpeechServerManager(launcherOverride: launcher)
        do {
            try await manager.start()
            let endpoint = try XCTUnwrap(manager.endpoint)
            let token = try XCTUnwrap(manager.token)
            let voices = try await TextToSpeechClient().voices(endpoint: endpoint, token: token)
            XCTAssertEqual(voices.map(\.id), ["ryan"])
            await manager.stop()
        } catch {
            await manager.stop()
            throw error
        }
    }

    func testFreshSettingsDefaultToRyanWithoutReplacingSavedVoice() {
        let suite = "LocalDictationTests.TTSSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(TextToSpeechSettings(defaults: defaults).defaultVoiceID, "ryan")
        defaults.set("aiden", forKey: "textToSpeechVoiceID")
        XCTAssertEqual(TextToSpeechSettings(defaults: defaults).defaultVoiceID, "aiden")
        defaults.removePersistentDomain(forName: suite)
    }

    func testSaveAndUsePersistsCompleteVoiceConfigurationAndKeepsOtherVoiceProfiles() throws {
        let suite = "LocalDictationTests.TTSVoiceProfiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var settings = TextToSpeechSettings(defaults: defaults)
        try settings.saveAndUseVoiceConfiguration(.init(
            voiceID: "ryan", voicePrompt: "Warm and measured.", pronunciationOverridesText: "Qwen = kwen"
        ))
        try settings.saveAndUseVoiceConfiguration(.init(
            voiceID: "voice-design", voicePrompt: "A calm English documentary narrator.", pronunciationOverridesText: "harbour = harbor"
        ))
        XCTAssertEqual(settings.activeVoiceConfiguration.voiceID, "voice-design-consistent")
        settings.useSavedVoice("ryan")
        XCTAssertEqual(settings.activeVoiceConfiguration.voicePrompt, "Warm and measured.")
        XCTAssertEqual(settings.savedVoiceConfiguration(for: "voice-design-consistent").voicePrompt, "A calm English documentary narrator.")
        settings.useSavedVoice("voice-design")
        XCTAssertEqual(settings.activeVoiceConfiguration.voiceID, "voice-design-consistent")
        XCTAssertEqual(settings.activeVoiceConfiguration.voicePrompt, "A calm English documentary narrator.")
        settings.persist(to: defaults)

        let restored = TextToSpeechSettings(defaults: defaults)
        XCTAssertEqual(restored.activeVoiceConfiguration, settings.activeVoiceConfiguration)
        XCTAssertEqual(
            restored.savedVoiceConfiguration(for: "voice-design-consistent").pronunciationOverridesText,
            "harbour = harbor"
        )
        defaults.removePersistentDomain(forName: suite)
    }

    func testSavingCustomVoiceWithoutDescriptionFailsBeforeRuntimeWork() {
        let suite = "LocalDictationTests.TTSCustomValidation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var settings = TextToSpeechSettings(defaults: defaults)
        XCTAssertThrowsError(try settings.saveAndUseVoiceConfiguration(.init(voiceID: "voice-design", voicePrompt: "   "))) {
            XCTAssertEqual($0.localizedDescription, TextToSpeechVoiceConfigurationError.customVoiceNeedsDescription.localizedDescription)
        }
        XCTAssertEqual(settings.activeVoiceConfiguration, .ryan)
        defaults.removePersistentDomain(forName: suite)
    }

    func testLegacyCustomVoiceMigratesToThePersistentCustomVoiceRoute() {
        let suite = "LocalDictationTests.TTSLegacyCustomVoice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("voice-design", forKey: "textToSpeechVoiceID")
        defaults.set("A calm, capable English narrator.", forKey: "textToSpeechVoicePrompt")
        defaults.set("Qwen = kwen", forKey: "textToSpeechPronunciationOverrides")

        let settings = TextToSpeechSettings(defaults: defaults)

        XCTAssertEqual(settings.activeVoiceConfiguration.voiceID, "voice-design-consistent")
        XCTAssertEqual(settings.activeVoiceConfiguration.voicePrompt, "A calm, capable English narrator.")
        XCTAssertEqual(settings.activeVoiceConfiguration.pronunciationOverridesText, "Qwen = kwen")
        XCTAssertTrue(settings.hasSavedVoiceConfiguration(for: "voice-design"))
        defaults.removePersistentDomain(forName: suite)
    }

    func testBlankLegacyCustomVoiceIsNotAnActivatableSavedVoice() {
        let suite = "LocalDictationTests.TTSBlankLegacyCustomVoice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("voice-design", forKey: "textToSpeechVoiceID")
        defaults.set("", forKey: "textToSpeechVoicePrompt")
        var settings = TextToSpeechSettings(defaults: defaults)

        XCTAssertEqual(settings.activeVoiceConfiguration.voiceID, "voice-design-consistent")
        XCTAssertFalse(settings.hasSavedVoiceConfiguration(for: "voice-design-consistent"))
        settings.useSavedVoice("ryan")
        settings.useSavedVoice("voice-design-consistent")
        XCTAssertEqual(settings.activeVoiceConfiguration.voiceID, "ryan")
        defaults.removePersistentDomain(forName: suite)
    }

    func testDraftConfigurationDoesNotChangeCurrentVoiceUntilExplicitSave() {
        let suite = "LocalDictationTests.TTSDraftDoesNotSave.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var settings = TextToSpeechSettings(defaults: defaults)
        let draft = TextToSpeechVoiceConfiguration(
            voiceID: "voice-design",
            voicePrompt: "An articulate English narrator with a warm, steady delivery.",
            pronunciationOverridesText: "Qwen = kwen"
        )

        // Previewing uses this separate value. Persisting settings before an
        // explicit Save & Use must retain Ryan as the global shortcut voice.
        XCTAssertNotEqual(draft, settings.activeVoiceConfiguration)
        XCTAssertFalse(settings.hasSavedVoiceConfiguration(for: "voice-design-consistent"))
        settings.useSavedVoice("voice-design-consistent")
        XCTAssertEqual(settings.activeVoiceConfiguration, .ryan)
        settings.persist(to: defaults)
        XCTAssertEqual(TextToSpeechSettings(defaults: defaults).activeVoiceConfiguration, .ryan)

        try? settings.saveAndUseVoiceConfiguration(draft)
        XCTAssertEqual(settings.activeVoiceConfiguration.voiceID, "voice-design-consistent")
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    func testStreamingProtocolSendsBearerAndDeliversOrderedEvents() async throws {
        TTSURLProtocol.responseStatus = 200
        TTSURLProtocol.responseBody = Data((
            "{\"type\":\"started\",\"job_id\":\"job-1\"}\n"
                + "{\"type\":\"audio_chunk\",\"job_id\":\"job-1\",\"index\":0,\"path\":\"/tmp/job-1/000.wav\"}\n"
                + "{\"type\":\"completed\",\"job_id\":\"job-1\"}\n"
        ).utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSURLProtocol.self]
        let client = TextToSpeechClient(session: URLSession(configuration: configuration))
        let payload = TextToSpeechRequest(
            jobID: "job-1",
            text: "Read this.",
            textPath: nil,
            voiceID: "ryan",
            voicePrompt: "Speak warmly.",
            outputPath: "/tmp/job-1",
            format: .wav,
            stream: true,
            chunkMaxCharacters: 500
        )
        var received: [String] = []
        try await client.stream(
            payload,
            endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:18000")),
            token: "test-token"
        ) { event in
            received.append(event.type)
        }

        XCTAssertEqual(received, ["started", "audio_chunk", "completed"])
        XCTAssertEqual(TTSURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(TTSURLProtocol.lastRequest?.httpMethod, "POST")
    }

    @MainActor
    func testStreamingProtocolRejectsUnauthorizedWorkerBeforeProcessingEvents() async throws {
        TTSURLProtocol.responseStatus = 401
        TTSURLProtocol.responseBody = Data("unauthorized".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSURLProtocol.self]
        let client = TextToSpeechClient(session: URLSession(configuration: configuration))
        let payload = TextToSpeechRequest(
            jobID: "job-2",
            text: "Read this.",
            textPath: nil,
            voiceID: "ryan",
            voicePrompt: nil,
            outputPath: "/tmp/job-2",
            format: .rf64,
            stream: false,
            chunkMaxCharacters: 500
        )
        do {
            try await client.stream(
                payload,
                endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:18000")),
                token: "wrong-token"
            ) { _ in
                XCTFail("An unauthorized response must not deliver worker events.")
            }
            XCTFail("Unauthorized worker unexpectedly accepted a request.")
        } catch {
            XCTAssertTrue(error is TextToSpeechError)
        }
    }

    @MainActor
    func testStreamingProtocolRejectsTruncatedOrMismatchedJobStream() async throws {
        TTSURLProtocol.responseStatus = 200
        TTSURLProtocol.responseBody = Data("{\"type\":\"started\",\"job_id\":\"other-job\"}\n".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSURLProtocol.self]
        let client = TextToSpeechClient(session: URLSession(configuration: configuration))
        let payload = TextToSpeechRequest(jobID: "job-3", text: "Read this.", textPath: nil, voiceID: "ryan", voicePrompt: nil, outputPath: "/tmp/job-3", format: .wav, stream: true, chunkMaxCharacters: 500)
        do {
            try await client.stream(payload, endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:18000")), token: "test") { _ in }
            XCTFail("A stream for another job must not be accepted.")
        } catch {
            XCTAssertTrue(error is TextToSpeechError)
        }
    }

    func testChunkPathRejectsTraversalAndSiblingDirectories() {
        let directory = URL(fileURLWithPath: "/tmp/local-dictation/job-1", isDirectory: true)
        XCTAssertTrue(TextToSpeechChunkPath.isSafe(
            path: "/tmp/local-dictation/job-1/job-1-000001.wav",
            in: directory
        ))
        XCTAssertFalse(TextToSpeechChunkPath.isSafe(
            path: "/tmp/local-dictation/job-1-other/job-1-000001.wav",
            in: directory
        ))
        XCTAssertFalse(TextToSpeechChunkPath.isSafe(
            path: "/tmp/local-dictation/job-1/../outside.wav",
            in: directory
        ))
    }

    func testExportStagingPathOnlyAcceptsThisJobsExactHiddenSibling() {
        let destination = URL(fileURLWithPath: "/tmp/generated/voice.wav")
        XCTAssertEqual(
            TextToSpeechExportStaging.validatedURL(
                path: "/tmp/generated/.voice.wav.job-1.partial",
                destination: destination,
                jobID: "job-1"
            )?.path,
            "/tmp/generated/.voice.wav.job-1.partial"
        )
        XCTAssertNil(TextToSpeechExportStaging.validatedURL(
            path: "/tmp/generated/voice.wav.partial", destination: destination, jobID: "job-1"
        ))
        XCTAssertNil(TextToSpeechExportStaging.validatedURL(
            path: "/tmp/generated/.other.wav.job-1.partial", destination: destination, jobID: "job-1"
        ))
        XCTAssertNil(TextToSpeechExportStaging.validatedURL(
            path: "/tmp/generated/.voice.wav.someone-else.partial", destination: destination, jobID: "job-1"
        ))
    }
}
