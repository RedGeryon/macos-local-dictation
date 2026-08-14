import Foundation

struct AppConfiguration: Equatable, Sendable {
    static let modelFileName = "nemotron-speech-streaming-en-0.6b.q8_0.gguf"
    static let modelPageURL = URL(string: "https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b")!
    static let modelLicenseURL = URL(string: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/")!
    static let runtimePageURL = URL(string: "https://github.com/NVIDIA/NeMo-Speech.cpp")!

    let engineURL: URL
    let modelURL: URL

    static func supportDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalDictation", isDirectory: true)
    }

    init(engineURL: URL, modelURL: URL) {
        self.engineURL = engineURL
        self.modelURL = modelURL
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

        self.engineURL = URL(fileURLWithPath: enginePath)
        self.modelURL = URL(fileURLWithPath: modelPath)
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
