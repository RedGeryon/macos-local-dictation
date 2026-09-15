import XCTest
@testable import LocalDictation

final class ModelStorageTests: XCTestCase {
    func testImportsAreContainedDiscoverableAndNeverOverwriteOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("custom.gguf")
        try Data("GGUFfixture".utf8).write(to: source)
        let support = root.appendingPathComponent("support")
        let first = try ModelStorage.importSpeechModel(from: source, support: support)
        let second = try ModelStorage.importSpeechModel(from: source, support: support)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: source))
        let suite = "LocalDictationTests.Storage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppConfiguration.installedSpeechModels(defaults: defaults, supportDirectory: support).count, 2)
    }

    func testInventoryIncludesPartialAndOptionalModelsAndRejectsExternalDeletion() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let speech = support.appendingPathComponent("Models")
        let voice = support.appendingPathComponent("TTSModels")
        try fm.createDirectory(at: speech, withIntermediateDirectories: true)
        try fm.createDirectory(at: voice, withIntermediateDirectories: true)
        let partial = speech.appendingPathComponent(".download-model.gguf")
        try Data("partial".utf8).write(to: partial)
        let component = voice.appendingPathComponent("qwen3-tts-1.7b-base-8bit")
        try fm.createDirectory(at: component, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external.gguf")
        try Data("GGUFfixture".utf8).write(to: external)
        let link = speech.appendingPathComponent("linked.gguf")
        try fm.createSymbolicLink(at: link, withDestinationURL: external)
        let items = ModelStorage.inventory(support: support, voiceModels: voice, speechModels: [.init(url: external, variant: .custom)])
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.url.standardizedFileURL == partial.standardizedFileURL }).isManaged)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.url.standardizedFileURL == component.standardizedFileURL }).isManaged)
        for item in items where item.url.standardizedFileURL == external.standardizedFileURL || item.url.standardizedFileURL == link.standardizedFileURL {
            XCTAssertFalse(item.isManaged)
            XCTAssertThrowsError(try ModelStorage.trash(item, support: support, voiceModels: voice, move: { _ in XCTFail("Must not delete external data") }))
        }
        let item = try XCTUnwrap(items.first { $0.url.standardizedFileURL == partial.standardizedFileURL })
        var moved: URL?
        try ModelStorage.trash(item, support: support, voiceModels: voice, move: { moved = $0 })
        XCTAssertEqual(moved?.standardizedFileURL, partial.standardizedFileURL)
        // Replacing a listed file with a symlink cannot bypass the removal check.
        try fm.removeItem(at: partial)
        try fm.createSymbolicLink(at: partial, withDestinationURL: external)
        XCTAssertThrowsError(try ModelStorage.trash(item, support: support, voiceModels: voice, move: { _ in XCTFail("Stale item must be revalidated") }))
    }
}
