import Foundation

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

        let storedEnginePath = defaults.string(forKey: "enginePath")
        let usableStoredEngine = storedEnginePath.flatMap {
            fileManager.isExecutableFile(atPath: $0) ? $0 : nil
        }
        let enginePath = environment["LOCAL_DICTATION_ENGINE_PATH"]
            ?? usableStoredEngine
            ?? defaultEngine.path
        let modelPath = environment["LOCAL_DICTATION_MODEL_PATH"]
            ?? defaults.string(forKey: "modelPath")
            ?? defaultModel.path
        let modelURL = URL(fileURLWithPath: modelPath)
        let modelVariant = SpeechModelVariant.identify(modelURL)
        let requestedLanguage = environment["LOCAL_DICTATION_LANGUAGE"]
            .flatMap(RecognitionLanguage.init(rawValue:))
            ?? defaults.string(forKey: "recognitionLanguage")
                .flatMap(RecognitionLanguage.init(rawValue:))
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
}
