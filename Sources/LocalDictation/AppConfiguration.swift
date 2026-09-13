import Foundation

enum LocalDictationPreviewIdentity {
    static let bundleIdentifier = "org.localdictation.app.tts-preview"
    static func isPreview(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleIdentifier == Self.bundleIdentifier
    }
}

enum TextToSpeechStorage {
    private static let runtimeKey = "previewTTSRuntimeDirectory"
    private static let modelsKey = "previewTTSModelsDirectory"

    static func runtimeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard, bundleURL: URL = Bundle.main.bundleURL, isPreview: Bool = LocalDictationPreviewIdentity.isPreview()) -> URL {
        directory(environment["LOCAL_DICTATION_TTS_RUNTIME_DIR"], key: runtimeKey, fallbackName: "tts-runtime", defaults: defaults, bundleURL: bundleURL, isPreview: isPreview)
    }
    static func modelsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard, bundleURL: URL = Bundle.main.bundleURL, isPreview: Bool = LocalDictationPreviewIdentity.isPreview()) -> URL {
        directory(environment["LOCAL_DICTATION_TTS_MODEL_DIR"], key: modelsKey, fallbackName: "tts-models", defaults: defaults, bundleURL: bundleURL, isPreview: isPreview)
    }
    static func capturePreviewDirectories(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard, bundleURL: URL = Bundle.main.bundleURL) {
        guard LocalDictationPreviewIdentity.isPreview() else { return }
        for (variable, key) in [("LOCAL_DICTATION_TTS_RUNTIME_DIR", runtimeKey), ("LOCAL_DICTATION_TTS_MODEL_DIR", modelsKey)] {
            guard let path = environment[variable], URL(fileURLWithPath: path).isFileURL, path.hasPrefix("/") else { continue }
            defaults.set(path, forKey: key)
        }
    }
    private static func directory(_ environmentPath: String?, key: String, fallbackName: String, defaults: UserDefaults, bundleURL: URL, isPreview: Bool) -> URL {
        if let environmentPath, environmentPath.hasPrefix("/") { return URL(fileURLWithPath: environmentPath) }
        if isPreview, let stored = defaults.string(forKey: key), stored.hasPrefix("/") {
            return URL(fileURLWithPath: stored)
        }
        if isPreview { return previewSiblingDirectory(bundleURL: bundleURL, name: fallbackName) }
        return AppConfiguration.supportDirectory().appendingPathComponent(fallbackName == "tts-runtime" ? "TTSRuntime" : "TTSModels", isDirectory: true)
    }
    static func previewSiblingDirectory(bundleURL: URL, name: String) -> URL {
        bundleURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
    }
}

/// Minutes of inactivity after which a loaded model is released. nil keeps it loaded.
typealias IdleUnloadMinutes = Int

enum IdleUnloadPolicy {
    /// The choices offered in Settings, with nil meaning "keep loaded".
    static let choices: [IdleUnloadMinutes?] = [nil, 5, 15, 30, 60]

    static func title(for minutes: IdleUnloadMinutes?) -> String {
        guard let minutes else { return "Keep loaded" }
        return "After \(minutes) minutes idle"
    }

    /// A model is released only when it is loaded, idle, and nothing is using it.
    static func shouldSchedule(minutes: IdleUnloadMinutes?, engineReady: Bool, busy: Bool) -> Bool {
        guard let minutes, minutes > 0 else { return false }
        return engineReady && !busy
    }
}

struct DictationFeatureSettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var loadAtStartup: Bool = true
    var idleUnloadMinutes: IdleUnloadMinutes? = nil
}

enum TextToSpeechModelChoice: String, CaseIterable, Codable, Sendable {
    case bf16 = "qwen-1.7b-bf16"
    case eightBit = "qwen-1.7b-8bit"
}

struct ReadAloudFeatureSettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var loadAtStartup: Bool = false
    var model: TextToSpeechModelChoice = .bf16
    var idleUnloadMinutes: IdleUnloadMinutes? = nil
}

struct LocalFeatureSettings: Codable, Equatable, Sendable {
    var dictation = DictationFeatureSettings()
    var readAloud = ReadAloudFeatureSettings()
    static let key = "localFeatureSettings"
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func persist(defaults: UserDefaults = .standard) { defaults.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

struct InstalledSpeechModel: Equatable, Identifiable, Sendable {
    let url: URL
    let variant: SpeechModelVariant
    var id: String { url.standardizedFileURL.path }
    var title: String { variant.title }
}

struct ModelCatalogConfiguration {
    let supportDirectory: URL
    let ttsModelsDirectory: URL
    let ttsRuntimeDirectory: URL
    let defaults: UserDefaults
    let appConfiguration: AppConfiguration?
    /// Test-only presentation fixtures can provide a stable lifecycle state
    /// without starting permissions, hotkeys, or a local worker.
    let initialState: AppState?

    init(supportDirectory: URL, ttsModelsDirectory: URL, ttsRuntimeDirectory: URL, defaults: UserDefaults, appConfiguration: AppConfiguration? = nil, initialState: AppState? = nil) {
        self.supportDirectory = supportDirectory; self.ttsModelsDirectory = ttsModelsDirectory
        self.ttsRuntimeDirectory = ttsRuntimeDirectory; self.defaults = defaults; self.appConfiguration = appConfiguration
        self.initialState = initialState
    }

    static func live() -> Self {
        .init(supportDirectory: AppConfiguration.supportDirectory(), ttsModelsDirectory: TextToSpeechStorage.modelsDirectory(), ttsRuntimeDirectory: TextToSpeechStorage.runtimeDirectory(), defaults: .standard)
    }
}

/// The lifecycle of one local engine. This deliberately distinguishes a disabled
/// engine from an enabled engine which has not been loaded yet.
enum LocalFeatureRuntimeStatus: Equatable, Sendable {
    case disabled
    case notLoaded
    case loading
    case ready
    case error(String)

    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .notLoaded: return "Not loaded"
        case .loading: return "Loading…"
        case .ready: return "Ready"
        case .error: return "Needs attention"
        }
    }
}

enum SpeechModelVariant: String, Equatable, Sendable {
    case english
    case multilingual
    case custom

    var title: String {
        switch self {
        case .english: return "English streaming model"
        case .multilingual: return "Multilingual streaming model"
        case .custom: return "Custom Nemotron GGUF model"
        }
    }

    var supportsLanguageSelection: Bool { self != .english }

    var recommendedLanguage: RecognitionLanguage {
        self == .multilingual ? .automatic : .englishUS
    }

    static func identify(_ modelURL: URL) -> SpeechModelVariant {
        let filename = modelURL.lastPathComponent.lowercased()
        if filename.contains("nemotron-3.5-asr-streaming-0.6b") { return .multilingual }
        if filename.contains("nemotron-speech-streaming-en-0.6b") { return .english }
        return .custom
    }
}

enum RecognitionLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case spanishUS = "es-US"
    case spanishSpain = "es-ES"
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case frenchFrance = "fr-FR"
    case frenchCanada = "fr-CA"
    case italian = "it-IT"
    case portugueseBrazil = "pt-BR"
    case portuguesePortugal = "pt-PT"
    case dutch = "nl-NL"
    case german = "de-DE"
    case turkish = "tr-TR"
    case russian = "ru-RU"
    case arabic = "ar-AR"
    case hindi = "hi-IN"
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case vietnamese = "vi-VN"
    case ukrainian = "uk-UA"
    case polish = "pl-PL"
    case swedish = "sv-SE"
    case czech = "cs-CZ"
    case norwegianBokmal = "nb-NO"
    case danish = "da-DK"
    case bulgarian = "bg-BG"
    case finnish = "fi-FI"
    case croatian = "hr-HR"
    case slovak = "sk-SK"
    case mandarin = "zh-CN"
    case hungarian = "hu-HU"
    case romanian = "ro-RO"
    case estonian = "et-EE"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Auto-detect language"
        case .spanishUS: return "Spanish (United States)"
        case .spanishSpain: return "Spanish (Spain)"
        case .englishUS: return "English (United States)"
        case .englishUK: return "English (United Kingdom)"
        case .frenchFrance: return "French (France)"
        case .frenchCanada: return "French (Canada)"
        case .italian: return "Italian"
        case .portugueseBrazil: return "Portuguese (Brazil)"
        case .portuguesePortugal: return "Portuguese (Portugal)"
        case .dutch: return "Dutch"
        case .german: return "German"
        case .turkish: return "Turkish"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .vietnamese: return "Vietnamese"
        case .ukrainian: return "Ukrainian"
        case .polish: return "Polish"
        case .swedish: return "Swedish"
        case .czech: return "Czech"
        case .norwegianBokmal: return "Norwegian Bokmål"
        case .danish: return "Danish"
        case .bulgarian: return "Bulgarian"
        case .finnish: return "Finnish"
        case .croatian: return "Croatian"
        case .slovak: return "Slovak"
        case .mandarin: return "Mandarin Chinese"
        case .hungarian: return "Hungarian"
        case .romanian: return "Romanian"
        case .estonian: return "Estonian"
        }
    }
}

struct AppConfiguration: Equatable, Sendable {
    static let modelFileName = "nemotron-speech-streaming-en-0.6b.q8_0.gguf"
    static let multilingualModelFileName = "nemotron-3.5-asr-streaming-0.6b.q8_0.gguf"
    static let englishModelPageURL = URL(string: "https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b")!
    static let englishModelDownloadURL = URL(string: "https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b/resolve/ebe59e5a817142986528bbbee5dba8db7b38ed50/nemotron-speech-streaming-en-0.6b.q8_0.gguf?download=true")!
    static let englishModelLicenseURL = URL(string: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/")!
    static let multilingualModelPageURL = URL(string: "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b")!
    static let multilingualModelDownloadURL = URL(string: "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/resolve/1c8deaecc64b91f034d73e08dd8b64625eb3395d/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf?download=true")!
    static let multilingualModelLicenseURL = URL(string: "https://openmdw.ai/license/1-1/")!
    static let runtimePageURL = URL(string: "https://github.com/NVIDIA/NeMo-Speech.cpp")!

    let engineURL: URL
    let modelURL: URL
    let recognitionLanguage: RecognitionLanguage

    var modelVariant: SpeechModelVariant { .identify(modelURL) }

    var modelPageURL: URL {
        modelVariant == .multilingual ? Self.multilingualModelPageURL : Self.englishModelPageURL
    }

    var modelLicenseURL: URL {
        modelVariant == .multilingual ? Self.multilingualModelLicenseURL : Self.englishModelLicenseURL
    }

    static func supportDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalDictation", isDirectory: true)
    }

    init(
        engineURL: URL,
        modelURL: URL,
        recognitionLanguage: RecognitionLanguage? = nil
    ) {
        self.engineURL = engineURL
        self.modelURL = modelURL
        let variant = SpeechModelVariant.identify(modelURL)
        let requestedLanguage = recognitionLanguage ?? variant.recommendedLanguage
        self.recognitionLanguage = variant == .english ? .englishUS : requestedLanguage
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        let support = Self.supportDirectory(fileManager: fileManager)

        let bundledEngine = Bundle.main.resourceURL?
            .appendingPathComponent("Engine", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("nemo-speech")

        let installedEngine = support
            .appendingPathComponent("Engine", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("nemo-speech")
        let defaultEngine = bundledEngine.map { fileManager.isExecutableFile(atPath: $0.path) ? $0 : installedEngine }
            ?? installedEngine
        let defaultModel = support
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Self.modelFileName)

        // The preview has its own bundle identifier and therefore its own
        // UserDefaults domain. It must still be able to use an existing
        // production ASR installation when it has no explicit ASR choice.
        let productionDefaults = LocalDictationPreviewIdentity.isPreview()
            ? UserDefaults(suiteName: "org.localdictation.app")
            : nil
        let storedEnginePath = defaults.string(forKey: "enginePath")
            ?? productionDefaults?.string(forKey: "enginePath")
        let usableStoredEngine = storedEnginePath.flatMap {
            fileManager.isExecutableFile(atPath: $0) ? $0 : nil
        }
        let enginePath = environment["LOCAL_DICTATION_ENGINE_PATH"]
            ?? usableStoredEngine
            ?? defaultEngine.path
        let modelPath = environment["LOCAL_DICTATION_MODEL_PATH"]
            ?? defaults.string(forKey: "modelPath")
            ?? productionDefaults?.string(forKey: "modelPath")
            ?? defaultModel.path
        let modelURL = URL(fileURLWithPath: modelPath)
        let modelVariant = SpeechModelVariant.identify(modelURL)
        let storedLanguage = defaults.string(forKey: "recognitionLanguage")
            .flatMap(RecognitionLanguage.init(rawValue:))
        let previewLanguage = productionDefaults?.string(forKey: "recognitionLanguage")
            .flatMap(RecognitionLanguage.init(rawValue:))
        let requestedLanguage = environment["LOCAL_DICTATION_LANGUAGE"]
            .flatMap(RecognitionLanguage.init(rawValue:))
            ?? storedLanguage
            ?? previewLanguage
            ?? modelVariant.recommendedLanguage

        self.engineURL = URL(fileURLWithPath: enginePath)
        self.modelURL = modelURL
        self.recognitionLanguage = modelVariant == .english ? .englishUS : requestedLanguage
    }

    func validate(fileManager: FileManager = .default) -> ConfigurationIssue? {
        if let engineIssue = validateEngine(fileManager: fileManager) {
            return engineIssue
        }
        return validateModel(fileManager: fileManager)
    }

    func validateEngine(fileManager: FileManager = .default) -> ConfigurationIssue? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: engineURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .engineMissing
        }
        guard fileManager.isExecutableFile(atPath: engineURL.path) else {
            return .engineNotExecutable
        }
        return nil
    }

    func validateModel(fileManager: FileManager = .default) -> ConfigurationIssue? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: modelURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .modelMissing
        }
        guard Self.isGGUF(modelURL) else {
            return .modelNotGGUF
        }
        return nil
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(engineURL.path, forKey: "enginePath")
        defaults.set(modelURL.path, forKey: "modelPath")
        defaults.set(recognitionLanguage.rawValue, forKey: "recognitionLanguage")
    }

    static func isGGUF(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gguf",
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }

    static func installedSpeechModels(
        currentModelURL: URL? = nil,
        defaults: UserDefaults = .standard,
        supportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [InstalledSpeechModel] {
        let models = (supportDirectory ?? Self.supportDirectory(fileManager: fileManager)).appendingPathComponent("Models", isDirectory: true)
        let known = [models.appendingPathComponent(modelFileName), models.appendingPathComponent(multilingualModelFileName)]
        let remembered = (defaults.array(forKey: "knownSpeechModelPaths") as? [String] ?? []).map(URL.init(fileURLWithPath:))
        let candidates = known + remembered + (currentModelURL.map { [$0] } ?? [])
        var seen = Set<String>()
        return candidates.compactMap { url in
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized.path).inserted, isGGUF(normalized) else { return nil }
            return InstalledSpeechModel(url: normalized, variant: SpeechModelVariant.identify(normalized))
        }
    }

    static func rememberSpeechModel(_ url: URL, defaults: UserDefaults = .standard) {
        let path = url.standardizedFileURL.path
        var paths = defaults.array(forKey: "knownSpeechModelPaths") as? [String] ?? []
        paths.removeAll { $0 == path }
        paths.append(path)
        defaults.set(Array(paths.suffix(20)), forKey: "knownSpeechModelPaths")
    }
}
