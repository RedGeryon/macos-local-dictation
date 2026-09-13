@preconcurrency import AVFoundation
import AppKit
import Foundation
import OSLog
import Darwin

enum TextToSpeechState: Equatable, Sendable {
    case idle
    case starting
    case ready
    case speaking(paused: Bool)
    case generating
    case canceling
    case unavailable(String)
    case error(String)

    var label: String {
        switch self {
        case .idle, .ready: return "Ready"
        case .starting: return "Preparing text to speech…"
        case .speaking(let paused): return paused ? "Readback paused" : "Reading selected text…"
        case .generating: return "Generating audio…"
        case .canceling: return "Canceling text to speech…"
        case .unavailable: return "Text to speech needs setup"
        case .error: return "Text to speech needs attention"
        }
    }

    var isActive: Bool {
        switch self {
        case .starting, .speaking, .generating, .canceling: return true
        default: return false
        }
    }
}

enum TextToSpeechModelComponent: String, CaseIterable, Codable, Sendable {
    case customVoice
    case voiceDesign
    case base

    var title: String {
        switch self {
        case .customVoice: return "Preset voices"
        case .voiceDesign: return "Voice Design"
        case .base: return "Voice Replay"
        }
    }

    func downloadArgument(for model: TextToSpeechModelChoice) -> String {
        switch (self, model) {
        case (.customVoice, .bf16): return "custom"
        case (.customVoice, .eightBit): return "custom8"
        case (.voiceDesign, .bf16): return "design"
        case (.voiceDesign, .eightBit): return "design8"
        case (.base, .bf16): return "base"
        case (.base, .eightBit): return "base8"
        }
    }
}

enum TextToSpeechInstallState: Equatable, Sendable {
    case idle
    case settingUpRuntime
    case downloading(TextToSpeechModelComponent, TextToSpeechModelChoice)
    case completed(String)
    case failed(String)
    case canceling

    var isActive: Bool {
        switch self { case .settingUpRuntime, .downloading, .canceling: return true; default: return false }
    }
}

struct TextToSpeechModelInstallStatus: Equatable, Sendable {
    var runtimeInstalled: Bool
    var customVoiceInstalled: Bool
    var voiceDesignInstalled: Bool
    var baseInstalled: Bool

    static let unavailable = Self(runtimeInstalled: false, customVoiceInstalled: false, voiceDesignInstalled: false, baseInstalled: false)
}

struct InstalledTextToSpeechFamily: Equatable, Identifiable, Sendable {
    let model: TextToSpeechModelChoice
    let runtimeInstalled: Bool
    let customVoiceInstalled: Bool
    let voiceDesignInstalled: Bool
    let baseInstalled: Bool
    var id: String { model.rawValue }
    var isUsableForPresets: Bool { runtimeInstalled && customVoiceInstalled }
}

enum TextToSpeechModelCatalog {
    private static let expected: [TextToSpeechModelChoice: (custom: (String, String), design: (String, String), base: (String, String))] = [
        .bf16: (("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", "52f4770fd9726457eae3d3b6aa92047a25a10776"), ("mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", "7d3824abff87e49756bb0f83fb5411de75d160c4"), ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "a6eb4f68e4b056f1215157bb696209bc82a6db48")),
        .eightBit: (("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit", "41d3337e8b7f2843a75841595fc14e4b9a7a4b96"), ("mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit", "f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee"), ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", "e7dd0585652209fa0d7783659aad4e8a324de11c"))
    ]

    static func installedFamilies(modelsDirectory: URL, runtimeDirectory: URL, fileManager: FileManager = .default) -> [InstalledTextToSpeechFamily] {
        let runtime = fileManager.isExecutableFile(atPath: runtimeDirectory.appendingPathComponent("venv/bin/python").path)
            && fileManager.fileExists(atPath: runtimeDirectory.appendingPathComponent("requirements-resolved.txt").path)
        return TextToSpeechModelChoice.allCases.map { model in
            let spec = expected[model]!
            let suffix = model == .bf16 ? "bf16" : "8bit"
            func valid(_ name: String, _ expected: (String, String)) -> Bool {
                let directory = modelsDirectory.appendingPathComponent("qwen3-tts-1.7b-\(name)-\(suffix)")
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(".local-dictation-complete.json")),
                      let marker = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      marker["repository"] == expected.0, marker["revision"] == expected.1 else { return false }
                let required = ["config.json", "speech_tokenizer", "tokenizer_config.json", "vocab.json", "merges.txt"]
                return required.allSatisfy { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
                    && (try? fileManager.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".safetensors") && (try? directory.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 }) == true
            }
            return InstalledTextToSpeechFamily(model: model, runtimeInstalled: runtime, customVoiceInstalled: valid("customvoice", spec.custom), voiceDesignInstalled: valid("voicedesign", spec.design), baseInstalled: valid("base", spec.base))
        }
    }

    static func selectionAfterCompletedDownload(component: TextToSpeechModelComponent, downloaded: TextToSpeechModelChoice, current: TextToSpeechModelChoice, installed: [InstalledTextToSpeechFamily]) -> TextToSpeechModelChoice {
        guard component == .customVoice,
              !installed.contains(where: { $0.model == current && $0.customVoiceInstalled }) else { return current }
        return downloaded
    }
}

struct TextToSpeechVoice: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
}

extension TextToSpeechVoice {
    /// The two voices offered first everywhere: the default male preset and the
    /// default female preset. Both are built into the CustomVoice model, so they
    /// start instantly; a designed voice needs extra model passes and stays in
    /// the full list instead.
    static let primaryVoiceIDs = ["ryan", "vivian"]

    static let defaultVoiceID = "ryan"

    /// A stand-in for a preset voice before the worker has reported its list.
    static func placeholder(id: String) -> TextToSpeechVoice {
        switch id {
        case "ryan": return TextToSpeechVoice(id: id, name: "Ryan", description: "Confident male voice")
        case "vivian": return TextToSpeechVoice(id: id, name: "Vivian", description: "Warm, clear female voice")
        case "designed-narrator": return TextToSpeechVoice(id: id, name: "Designed Narrator", description: "")
        default: return TextToSpeechVoice(id: id, name: id, description: "")
        }
    }
}

struct TextToSpeechVoiceConfiguration: Codable, Equatable, Sendable {
    var voiceID: String
    var voicePrompt: String
    var pronunciationOverridesText: String

    static let ryan = Self(voiceID: "ryan", voicePrompt: "", pronunciationOverridesText: "")

    init(voiceID: String = "ryan", voicePrompt: String = "", pronunciationOverridesText: String = "") {
        self.voiceID = voiceID.isEmpty ? "ryan" : voiceID
        self.voicePrompt = voiceID == "designed-narrator" ? "" : voicePrompt
        self.pronunciationOverridesText = pronunciationOverridesText
    }
}

enum TextToSpeechVoiceConfigurationError: LocalizedError {
    case customVoiceNeedsDescription

    var errorDescription: String? {
        switch self {
        case .customVoiceNeedsDescription:
            return "Describe the custom narrator voice before saving it as your current voice."
        }
    }
}

enum TextToSpeechFormat: String, CaseIterable, Identifiable, Sendable {
    case wav
    case rf64

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wav: return "WAV"
        case .rf64: return "RF64 WAV (long files)"
        }
    }

    var filenameExtension: String { "wav" }
}

struct TextToSpeechSettings: Equatable, Sendable {
    private static let activeVoiceConfigurationKey = "textToSpeechActiveVoiceConfiguration"
    var activeVoiceConfiguration: TextToSpeechVoiceConfiguration
    private(set) var savedVoiceConfigurations: [String: TextToSpeechVoiceConfiguration]
    var shortcutsEnabled: Bool

    private struct PersistedVoiceConfigurations: Codable {
        let active: TextToSpeechVoiceConfiguration
        let saved: [String: TextToSpeechVoiceConfiguration]
    }

    var defaultVoiceID: String {
        activeVoiceConfiguration.voiceID
    }

    var voicePrompt: String {
        activeVoiceConfiguration.voicePrompt
    }

    var pronunciationOverridesText: String {
        activeVoiceConfiguration.pronunciationOverridesText
    }

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: Self.activeVoiceConfigurationKey),
           let persisted = try? JSONDecoder().decode(PersistedVoiceConfigurations.self, from: data) {
            activeVoiceConfiguration = persisted.active
            savedVoiceConfigurations = persisted.saved
        } else if let data = defaults.data(forKey: Self.activeVoiceConfigurationKey),
                  let configuration = try? JSONDecoder().decode(TextToSpeechVoiceConfiguration.self, from: data) {
            // One-release migration from the earlier single saved configuration.
            activeVoiceConfiguration = configuration
            savedVoiceConfigurations = [configuration.voiceID: configuration]
        } else {
            activeVoiceConfiguration = TextToSpeechVoiceConfiguration(
                voiceID: defaults.string(forKey: "textToSpeechVoiceID") ?? "ryan",
                voicePrompt: defaults.string(forKey: "textToSpeechVoicePrompt") ?? "",
                pronunciationOverridesText: defaults.string(forKey: "textToSpeechPronunciationOverrides") ?? ""
            )
            savedVoiceConfigurations = [activeVoiceConfiguration.voiceID: activeVoiceConfiguration]
        }
        // Older previews stored a one-off `voice-design` request. Keep its
        // description and pronunciations, but route it through the persisted
        // reference-based custom voice on subsequent jobs.
        if activeVoiceConfiguration.voiceID == "voice-design" {
            activeVoiceConfiguration.voiceID = "voice-design-consistent"
        }
        if activeVoiceConfiguration.voiceID == "designed-narrator" {
            activeVoiceConfiguration.voicePrompt = ""
        }
        if var legacyCustomVoice = savedVoiceConfigurations.removeValue(forKey: "voice-design") {
            legacyCustomVoice.voiceID = "voice-design-consistent"
            if savedVoiceConfigurations[legacyCustomVoice.voiceID] == nil {
                savedVoiceConfigurations[legacyCustomVoice.voiceID] = legacyCustomVoice
            }
        }
        savedVoiceConfigurations = savedVoiceConfigurations.mapValues { configuration in
            guard configuration.voiceID == "designed-narrator" else { return configuration }
            var fixedNarrator = configuration
            fixedNarrator.voicePrompt = ""
            return fixedNarrator
        }
        savedVoiceConfigurations[activeVoiceConfiguration.voiceID] = activeVoiceConfiguration
        shortcutsEnabled = defaults.object(forKey: "textToSpeechShortcutsEnabled") as? Bool ?? true
    }

    func savedVoiceConfiguration(for voiceID: String) -> TextToSpeechVoiceConfiguration {
        let savedVoiceID = voiceID == "voice-design" ? "voice-design-consistent" : voiceID
        return savedVoiceConfigurations[savedVoiceID] ?? TextToSpeechVoiceConfiguration(voiceID: savedVoiceID)
    }

    func hasSavedVoiceConfiguration(for voiceID: String) -> Bool {
        let savedVoiceID = voiceID == "voice-design" ? "voice-design-consistent" : voiceID
        guard let configuration = savedVoiceConfigurations[savedVoiceID] else { return false }
        if savedVoiceID == "voice-design-consistent" {
            return !configuration.voicePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    mutating func saveAndUseVoiceConfiguration(_ configuration: TextToSpeechVoiceConfiguration) throws {
        var saved = configuration
        if saved.voiceID == "voice-design" { saved.voiceID = "voice-design-consistent" }
        if saved.voiceID == "designed-narrator" { saved.voicePrompt = "" }
        if saved.voiceID == "voice-design-consistent",
           saved.voicePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TextToSpeechVoiceConfigurationError.customVoiceNeedsDescription
        }
        savedVoiceConfigurations[saved.voiceID] = saved
        activeVoiceConfiguration = saved
    }

    mutating func useSavedVoice(_ voiceID: String) {
        // The Custom voice represents a stored VoiceDesign→Base profile. It is
        // not a usable preset until a description has been explicitly saved.
        if voiceID == "voice-design" || voiceID == "voice-design-consistent" {
            guard hasSavedVoiceConfiguration(for: voiceID) else { return }
        }
        activeVoiceConfiguration = savedVoiceConfiguration(for: voiceID)
    }

    func persist(to defaults: UserDefaults = .standard) {
        // Voice identity, delivery instruction, and pronunciations change together.
        // A single encoded value prevents a later launch observing a partial save.
        let persisted = PersistedVoiceConfigurations(active: activeVoiceConfiguration, saved: savedVoiceConfigurations)
        defaults.set(try? JSONEncoder().encode(persisted), forKey: Self.activeVoiceConfigurationKey)
        defaults.set(shortcutsEnabled, forKey: "textToSpeechShortcutsEnabled")
    }
}

struct TextToSpeechRequest: Encodable, Sendable {
    let jobID: String
    let text: String?
    let textPath: String?
    let voiceID: String
    let modelID: TextToSpeechModelChoice
    let voicePrompt: String?
    let outputPath: String
    let format: TextToSpeechFormat
    let stream: Bool
    let chunkMaxCharacters: Int?
    let pronunciationOverrides: [TextToSpeechPronunciationOverride]

    init(jobID: String, text: String?, textPath: String?, voiceID: String, modelID: TextToSpeechModelChoice = .bf16, voicePrompt: String?, outputPath: String, format: TextToSpeechFormat, stream: Bool, chunkMaxCharacters: Int?, pronunciationOverrides: [TextToSpeechPronunciationOverride] = []) {
        self.jobID = jobID
        self.text = text
        self.textPath = textPath
        self.voiceID = voiceID
        self.modelID = modelID
        self.voicePrompt = voicePrompt
        self.outputPath = outputPath
        self.format = format
        self.stream = stream
        self.chunkMaxCharacters = chunkMaxCharacters
        self.pronunciationOverrides = pronunciationOverrides
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case text
        case textPath = "text_path"
        case voiceID = "voice_id"
        case modelID = "model_id"
        case voicePrompt = "voice_prompt"
        case language
        case outputPath = "output_path"
        case format
        case stream
        case chunkMaxCharacters = "chunk_max_chars"
        case pronunciationOverrides = "pronunciation_overrides"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jobID, forKey: .jobID)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(textPath, forKey: .textPath)
        try container.encode(voiceID, forKey: .voiceID)
        try container.encode(modelID.rawValue, forKey: .modelID)
        try container.encodeIfPresent(voicePrompt?.nilIfBlank, forKey: .voicePrompt)
        try container.encode("English", forKey: .language)
        try container.encode(outputPath, forKey: .outputPath)
        try container.encode(format.rawValue, forKey: .format)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(chunkMaxCharacters, forKey: .chunkMaxCharacters)
        try container.encode(pronunciationOverrides, forKey: .pronunciationOverrides)
    }
}

struct TextToSpeechPronunciationOverride: Codable, Equatable, Sendable {
    let from: String
    let to: String
}

struct TextToSpeechResponse: Decodable, Equatable, Sendable {
    let jobID: String?
    let durationSeconds: Double?
    let sampleRate: Int?
    let bytes: Int?
    let audioChunks: Int?
    let frames: Int?
    let errorDetail: String?
    let stagingPath: String?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case bytes
        case audioChunks = "audio_chunks"
        case frames
        case errorDetail = "error"
        case stagingPath = "staging_path"
    }
}

struct TextToSpeechStreamEvent: Decodable, Sendable {
    let type: String
    let jobID: String?
    let index: Int?
    let path: String?
    let durationMilliseconds: Int?
    let fraction: Double?
    let message: String?
    let durationSeconds: Double?
    let sampleRate: Int?
    let bytes: Int?
    let audioChunks: Int?
    let frames: Int?
    let errorDetail: String?
    let stagingPath: String?

    enum CodingKeys: String, CodingKey {
        case type
        case jobID = "job_id"
        case index
        case path
        case durationMilliseconds = "duration_ms"
        case fraction
        case message
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case bytes
        case audioChunks = "audio_chunks"
        case frames
        case errorDetail = "error"
        case stagingPath = "staging_path"
    }
}

enum TextToSpeechError: LocalizedError {
    case runtimeMissing
    case runtimeDidNotStart
    case server(String)
    case invalidResponse
    case playbackFailed
    case noSelectedText
    case secureTextField
    case noStandardSelection

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            return "Text to speech is not installed. Open Models & Startup to set up the selected voice model."
        case .runtimeDidNotStart:
            return "The local text-to-speech worker did not become ready. Open Models & Startup to check the selected model and runtime."
        case .server(let message): return message
        case .invalidResponse: return "The local text-to-speech worker returned an invalid response."
        case .playbackFailed: return "The generated audio could not be played."
        case .noSelectedText: return "Select text in a standard editable field, then try Read Selected Text."
        case .secureTextField: return "Text readback is disabled in password and secure text fields."
        case .noStandardSelection:
            return "This app does not expose its selected text to macOS. Use Read Clipboard instead."
        }
    }
}

@MainActor
final class TextToSpeechServerManager {
    private let logger = Logger(subsystem: "org.localdictation.app", category: "TextToSpeechServer")
    private let launcherOverride: URL?
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var standardOutputBuffer = Data()
    private var standardErrorBuffer = Data()
    private var startupErrorDetail: String?
    private var baseURL: URL?
    private var bearerToken = ""

    var isRunning: Bool { process?.isRunning == true && baseURL != nil }
    var endpoint: URL? { baseURL }
    var token: String? { isRunning ? bearerToken : nil }

    init(launcherOverride: URL? = nil) {
        self.launcherOverride = launcherOverride
    }

    func start(modelID: TextToSpeechModelChoice = .bf16) async throws {
        if isRunning { return }
        guard let launcher = launcherOverride ?? runtimeLauncherURL() else { throw TextToSpeechError.runtimeMissing }

        await stop()
        startupErrorDetail = nil
        let output = Pipe()
        let errors = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = [launcher.path]
        bearerToken = UUID().uuidString + UUID().uuidString
        var environment = ProcessInfo.processInfo.environment
        environment["LOCAL_DICTATION_TTS_BEARER_TOKEN"] = bearerToken
        environment["LOCAL_DICTATION_TTS_RUNTIME_DIR"] = TextToSpeechStorage.runtimeDirectory().path
        environment["LOCAL_DICTATION_TTS_MODEL_DIR"] = TextToSpeechStorage.modelsDirectory().path
        environment["LOCAL_DICTATION_TTS_MODEL_ID"] = modelID.rawValue
        environment["LOCAL_DICTATION_TTS_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        child.environment = environment
        child.standardOutput = output
        child.standardError = errors
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self, self.process?.processIdentifier == terminated.processIdentifier else { return }
                self.logger.error("TTS_SERVER_EXIT code=\(terminated.terminationStatus, privacy: .public)")
                self.baseURL = nil
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consumeStandardOutput(data, processID: child.processIdentifier) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consumeStandardError(data, processID: child.processIdentifier) }
        }

        do {
            // The worker prints its ready JSON immediately. Register the child before
            // starting it so a fast pipe callback cannot discard that first line.
            process = child
            outputPipe = output
            errorPipe = errors
            try child.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            if process === child {
                process = nil
                outputPipe = nil
                errorPipe = nil
            }
            throw TextToSpeechError.server("The local text-to-speech worker could not start: \(error.localizedDescription)")
        }
        do {
            for _ in 0..<300 {
                try Task.checkCancellation()
                if isRunning { return }
                guard child.isRunning else {
                    drainStandardError(from: errors, processID: child.processIdentifier)
                    throw TextToSpeechError.server(startupFailureMessage(exitStatus: child.terminationStatus))
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw TextToSpeechError.server(startupFailureMessage())
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        standardOutputBuffer.removeAll(keepingCapacity: false)
        standardErrorBuffer.removeAll(keepingCapacity: false)
        baseURL = nil
        bearerToken = ""
        guard let child = process else { return }
        guard child.isRunning else {
            if process?.processIdentifier == child.processIdentifier { process = nil }
            return
        }
        child.terminate()
        let deadline = ContinuousClock.now + .seconds(2)
        while child.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        if process?.processIdentifier == child.processIdentifier { process = nil }
    }

    func forceStop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        standardOutputBuffer.removeAll(keepingCapacity: false)
        standardErrorBuffer.removeAll(keepingCapacity: false)
        baseURL = nil
        bearerToken = ""
        guard let child = process else { return }
        if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        if process?.processIdentifier == child.processIdentifier { process = nil }
    }

    private func runtimeLauncherURL(fileManager: FileManager = .default) -> URL? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("TTSEngine", isDirectory: true)
            .appendingPathComponent("run-tts-server.sh"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let developmentCandidates = [
            workingDirectory.appendingPathComponent("scripts/run-tts-server.sh"),
            workingDirectory.appendingPathComponent("python/run-tts-server.sh")
        ]
        return developmentCandidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func consumeStandardOutput(_ data: Data, processID: Int32) {
        guard process?.processIdentifier == processID else { return }
        standardOutputBuffer.append(data)
        while let newline = standardOutputBuffer.firstIndex(of: 10) {
            let line = standardOutputBuffer.prefix(upTo: newline)
            standardOutputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["ready"] as? Bool == true,
                  let port = object["port"] as? Int,
                  (1...65_535).contains(port) else { continue }
            baseURL = URL(string: "http://127.0.0.1:\(port)")
            logger.info("TTS_SERVER_READY port=\(port, privacy: .public)")
        }
    }

    private func consumeStandardError(_ data: Data, processID: Int32) {
        guard process?.processIdentifier == processID else { return }
        appendStandardError(data)
    }

    private func drainStandardError(from pipe: Pipe, processID: Int32) {
        guard process?.processIdentifier == processID else { return }
        let data = pipe.fileHandleForReading.availableData
        guard !data.isEmpty else { return }
        appendStandardError(data)
    }

    private func appendStandardError(_ data: Data) {
        standardErrorBuffer.append(data)
        if standardErrorBuffer.count > 2_048 { standardErrorBuffer.removeFirst(standardErrorBuffer.count - 2_048) }
        let text = String(decoding: standardErrorBuffer, as: UTF8.self)
        let compact = text.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !compact.isEmpty { startupErrorDetail = compact }
    }

    private func startupFailureMessage(exitStatus: Int32? = nil) -> String {
        guard let detail = startupErrorDetail, !detail.isEmpty else {
            if let exitStatus {
                return "The local text-to-speech worker exited before it became ready (exit \(exitStatus))."
            }
            return "The local text-to-speech worker did not become ready. Check that the local runtime and model are installed."
        }
        return "The local text-to-speech worker did not become ready: \(detail.prefix(600))"
    }
}

@MainActor
final class TextToSpeechClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func voices(endpoint: URL, token: String) async throws -> [TextToSpeechVoice] {
        let request = authorizedRequest(endpoint.appendingPathComponent("v1/voices"), token: token)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        if let direct = try? JSONDecoder().decode([TextToSpeechVoice].self, from: data) { return direct }
        struct Envelope: Decodable { let voices: [TextToSpeechVoice] }
        return try JSONDecoder().decode(Envelope.self, from: data).voices
    }

    func preload(modelID: TextToSpeechModelChoice, voiceID: String, endpoint: URL, token: String) async throws {
        struct Payload: Encodable {
            let modelID: String
            let voiceID: String
            enum CodingKeys: String, CodingKey { case modelID = "model_id"; case voiceID = "voice_id" }
        }
        var request = authorizedRequest(endpoint.appendingPathComponent("v1/models/preload"), token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(modelID: modelID.rawValue, voiceID: voiceID))
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func unloadModel(endpoint: URL, token: String) async {
        var request = authorizedRequest(endpoint.appendingPathComponent("v1/models/unload"), token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try? await session.data(for: request)
    }

    func stream(
        _ payload: TextToSpeechRequest,
        endpoint: URL,
        token: String,
        onEvent: @escaping @MainActor (TextToSpeechStreamEvent) async throws -> Void
    ) async throws {
        var request = authorizedRequest(endpoint.appendingPathComponent("v1/tts"), token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TextToSpeechError.server("The local text-to-speech worker rejected the request.")
        }
        var receivedTerminalEvent = false
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            let event: TextToSpeechStreamEvent
            do { event = try JSONDecoder().decode(TextToSpeechStreamEvent.self, from: data) }
            catch { throw TextToSpeechError.invalidResponse }
            guard event.jobID == payload.jobID else { throw TextToSpeechError.invalidResponse }
            switch event.type {
            case "error":
                throw TextToSpeechError.server(event.message ?? event.errorDetail ?? "The local text-to-speech worker could not generate audio.")
            case "cancelled":
                throw CancellationError()
            case "completed":
                guard !receivedTerminalEvent else { throw TextToSpeechError.invalidResponse }
                receivedTerminalEvent = true
                try await onEvent(event)
            case "started", "audio_chunk", "progress":
                guard !receivedTerminalEvent else { throw TextToSpeechError.invalidResponse }
                try await onEvent(event)
            default:
                throw TextToSpeechError.invalidResponse
            }
        }
        guard receivedTerminalEvent else { throw TextToSpeechError.invalidResponse }
    }

    func acknowledge(jobID: String, index: Int, endpoint: URL, token: String) async {
        struct Acknowledgement: Encodable { let jobID: String; let index: Int
            enum CodingKeys: String, CodingKey { case jobID = "job_id"; case index }
        }
        var request = authorizedRequest(endpoint.appendingPathComponent("v1/tts/ack"), token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Acknowledgement(jobID: jobID, index: index))
        _ = try? await session.data(for: request)
    }

    func cancel(jobID: String, endpoint: URL, token: String) async {
        struct Cancellation: Encodable { let jobID: String
            enum CodingKeys: String, CodingKey { case jobID = "job_id" }
        }
        var request = authorizedRequest(endpoint.appendingPathComponent("v1/tts/cancel"), token: token)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Cancellation(jobID: jobID))
        _ = try? await session.data(for: request)
    }

    private func authorizedRequest(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TextToSpeechError.server(detail?.isEmpty == false ? detail! : "The local text-to-speech worker rejected the request.")
        }
    }
}

@MainActor
final class TextToSpeechPlaybackController {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var queuedBufferCount = 0
    private var paused = false
    private var producerCompleted = false
    private var activeGeneration: UUID?
    private var configuredFormat: AVAudioFormat?
    private var drainedContinuations: [CheckedContinuation<Void, Error>] = []

    init() {
        engine.attach(player)
    }

    var isPaused: Bool { paused }

    @discardableResult
    func begin() -> UUID {
        stop()
        let generation = UUID()
        activeGeneration = generation
        return generation
    }

    func enqueue(url: URL, generation: UUID, onPlayedBack: @escaping @MainActor () -> Void) throws {
        guard activeGeneration == generation else { throw CancellationError() }
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TextToSpeechError.playbackFailed
        }
        let frameCount = AVAudioFrameCount(min(audioFile.length, Int64(UInt32.max)))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            throw TextToSpeechError.playbackFailed
        }
        do {
            try audioFile.read(into: buffer)
            try configure(format: buffer.format)
            try startEngineIfNeeded()
        } catch {
            throw TextToSpeechError.playbackFailed
        }

        queuedBufferCount += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeGeneration == generation else { return }
                self.queuedBufferCount = max(0, self.queuedBufferCount - 1)
                onPlayedBack()
                self.resumeDrainedWaitersIfNeeded()
            }
        }
        if !paused { player.play() }
    }

    func pause() {
        guard !paused else { return }
        paused = true
        player.pause()
    }

    func resume() {
        guard paused else { return }
        paused = false
        player.play()
    }

    func producerDidComplete(generation: UUID) {
        guard activeGeneration == generation else { return }
        producerCompleted = true
        resumeDrainedWaitersIfNeeded()
    }

    func waitUntilDrained(generation: UUID) async throws {
        guard activeGeneration == generation else { throw CancellationError() }
        guard !(producerCompleted && queuedBufferCount == 0) else { return }
        try await withCheckedThrowingContinuation { continuation in
            drainedContinuations.append(continuation)
        }
    }

    func stop() {
        activeGeneration = nil
        player.stop()
        engine.stop()
        queuedBufferCount = 0
        paused = false
        producerCompleted = false
        configuredFormat = nil
        let continuations = drainedContinuations
        drainedContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    private func configure(format: AVAudioFormat) throws {
        if let configuredFormat {
            guard configuredFormat.sampleRate == format.sampleRate,
                  configuredFormat.channelCount == format.channelCount,
                  configuredFormat.commonFormat == format.commonFormat else {
                throw TextToSpeechError.playbackFailed
            }
            return
        }
        guard !engine.isRunning else { throw TextToSpeechError.playbackFailed }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        configuredFormat = format
    }

    private func resumeDrainedWaitersIfNeeded() {
        guard producerCompleted, queuedBufferCount == 0 else { return }
        let continuations = drainedContinuations
        drainedContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
        player.stop()
        engine.stop()
    }
}

enum SpeechAudioDocument {
    static func directory(fileManager: FileManager = .default) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents
            .appendingPathComponent("Local Dictation Transcripts", isDirectory: true)
            .appendingPathComponent("Generated Speech", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func suggestedURL(text: String, format: TextToSpeechFormat) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).prefix(5).joined(separator: " ")
        let title = words.isEmpty ? "Generated Speech" : String(words)
        let invalid = CharacterSet(charactersIn: "/:\\")
        let safe = title.components(separatedBy: invalid).joined(separator: "-")
        return try directory().appendingPathComponent(safe).appendingPathExtension(format.filenameExtension)
    }
}

enum TextToSpeechExportStaging {
    static func validatedURL(path: String, destination: URL, jobID: String) -> URL? {
        let directory = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent() == directory,
              candidate.lastPathComponent == ".\(destination.lastPathComponent).\(jobID).partial" else { return nil }
        return candidate
    }
}

enum TextToSpeechChunkPath {
    static func isSafe(path: String, in directory: URL) -> Bool {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return candidate.path.hasPrefix(root.path + "/")
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
