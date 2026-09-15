import Foundation

/// Only direct children of the configured model folders are app-managed.
/// External models and links remain visible, but are never deleted by the app.
struct StoredModel: Equatable {
    enum Kind { case speech, voice }
    let url: URL
    let kind: Kind
    let isManaged: Bool

    var title: String {
        if url.lastPathComponent.hasPrefix(".") { return "Unfinished download: " + url.lastPathComponent }
        if kind == .voice {
            let name = url.lastPathComponent
            let precision = name.hasSuffix("-8bit") ? "8-bit" : "BF16"
            let component = name.contains("customvoice") ? "Preset voices" : (name.contains("voicedesign") ? "Voice Design" : "Voice Replay")
            return "Qwen 1.7B (\(precision)) — \(component)"
        }
        if kind == .speech && url.pathExtension == "gguf" {
            return SpeechModelVariant.identify(url).title
        }
        return url.lastPathComponent
    }
}

enum ModelStorage {
    static func isManaged(_ url: URL, in directory: URL) -> Bool {
        let normalized = url.standardizedFileURL
        return normalized.deletingLastPathComponent() == directory.standardizedFileURL
            && (try? normalized.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
            && (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
    }

    static func inventory(support: URL, voiceModels: URL, speechModels: [InstalledSpeechModel], fileManager: FileManager = .default) -> [StoredModel] {
        let speechDirectory = support.appendingPathComponent("Models", isDirectory: true)
        var result: [StoredModel] = []
        for (directory, kind) in [(speechDirectory, StoredModel.Kind.speech), (voiceModels, .voice)] {
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in files {
                let name = url.lastPathComponent
                let matches = kind == .speech
                    ? (url.pathExtension.lowercased() == "gguf" || name.hasPrefix(".download-"))
                    : (name.hasPrefix("qwen3-tts-") || (name.hasPrefix(".qwen3-tts-") && name.hasSuffix(".download")))
                guard matches else { continue }
                result.append(.init(url: url, kind: kind, isManaged: isManaged(url, in: directory)))
            }
        }
        for model in speechModels where !result.contains(where: { $0.url.standardizedFileURL == model.url.standardizedFileURL }) {
            result.append(.init(url: model.url, kind: .speech, isManaged: false))
        }
        return result.sorted { $0.url.path < $1.url.path }
    }

    static func trash(_ item: StoredModel, support: URL, voiceModels: URL, move: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let directory = item.kind == .speech ? support.appendingPathComponent("Models", isDirectory: true) : voiceModels
        guard item.isManaged, isManaged(item.url, in: directory) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try move(item.url)
    }

    /// Copy imports into app storage without overwriting another installed model.
    static func importSpeechModel(from source: URL, support: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = support.appendingPathComponent("Models", isDirectory: true)
        guard AppConfiguration.isGGUF(source) else { throw ModelDownloadError.invalidGGUF }
        if isManaged(source, in: directory) { return source }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString + ".gguf")
        }
        do {
            try fileManager.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return destination
    }
}
