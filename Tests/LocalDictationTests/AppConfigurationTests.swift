import XCTest
@testable import LocalDictation

final class AppConfigurationTests: XCTestCase {
    func testPreviewIdentityAndSiblingStorageDoNotDependOnLaunchEnvironment() {
        XCTAssertTrue(LocalDictationPreviewIdentity.isPreview(bundleIdentifier: "org.localdictation.app.tts-preview"))
        XCTAssertFalse(LocalDictationPreviewIdentity.isPreview(bundleIdentifier: "org.localdictation.app"))
        let bundle = URL(fileURLWithPath: "/tmp/build/Local Dictation Preview.app", isDirectory: true)
        XCTAssertEqual(
            TextToSpeechStorage.previewSiblingDirectory(bundleURL: bundle, name: "tts-runtime").path,
            "/tmp/build/tts-runtime"
        )
        XCTAssertEqual(
            TextToSpeechStorage.previewSiblingDirectory(bundleURL: bundle, name: "tts-models").path,
            "/tmp/build/tts-models"
        )
        let suite = "LocalDictationTests.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/Volumes/Local/TTSRuntime", forKey: "previewTTSRuntimeDirectory")
        defaults.set("/Volumes/Local/TTSModels", forKey: "previewTTSModelsDirectory")
        XCTAssertEqual(TextToSpeechStorage.runtimeDirectory(environment: [:], defaults: defaults, bundleURL: bundle, isPreview: true).path, "/Volumes/Local/TTSRuntime")
        XCTAssertEqual(TextToSpeechStorage.modelsDirectory(environment: [:], defaults: defaults, bundleURL: bundle, isPreview: true).path, "/Volumes/Local/TTSModels")
        XCTAssertEqual(TextToSpeechStorage.runtimeDirectory(environment: ["LOCAL_DICTATION_TTS_RUNTIME_DIR": "/tmp/override"], defaults: defaults, bundleURL: bundle, isPreview: true).path, "/tmp/override")
    }

    func testFeatureSettingsDefaultToIndependentStartupPolicy() {
        let settings = LocalFeatureSettings()
        XCTAssertEqual(settings.dictation, DictationFeatureSettings(enabled: true, loadAtStartup: true))
        XCTAssertEqual(settings.readAloud, ReadAloudFeatureSettings(enabled: true, loadAtStartup: false, model: .bf16))
    }

    func testFeatureSettingsPersistBothEnginesAndSelectedTTSModel() throws {
        let suiteName = "LocalDictationTests.features.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = LocalFeatureSettings(
            dictation: .init(enabled: false, loadAtStartup: false),
            readAloud: .init(enabled: true, loadAtStartup: true, model: .eightBit)
        )
        expected.persist(defaults: defaults)
        XCTAssertEqual(LocalFeatureSettings.load(defaults: defaults), expected)
    }

    func testFeatureRuntimeStatesKeepDisabledAndNotLoadedDistinct() {
        XCTAssertEqual(LocalFeatureRuntimeStatus.disabled.label, "Disabled")
        XCTAssertEqual(LocalFeatureRuntimeStatus.notLoaded.label, "Not loaded")
        XCTAssertEqual(LocalFeatureRuntimeStatus.loading.label, "Loading…")
        XCTAssertEqual(LocalFeatureRuntimeStatus.ready.label, "Ready")
    }

    @MainActor
    func testInstalledSpeechSelectionPersistsInjectedChoiceWithoutLoadingWhenDisabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let models = support.appendingPathComponent("Models", isDirectory: true)
        let suite = "LocalDictationTests.selection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let english = models.appendingPathComponent(AppConfiguration.modelFileName)
        let multilingual = models.appendingPathComponent(AppConfiguration.multilingualModelFileName)
        try Data("GGUFenglish".utf8).write(to: english)
        try Data("GGUFmultilingual".utf8).write(to: multilingual)
        LocalFeatureSettings(
            dictation: .init(enabled: false, loadAtStartup: false),
            readAloud: .init(enabled: false, loadAtStartup: false, model: .bf16)
        ).persist(defaults: defaults)
        let coordinator = AppCoordinator(modelCatalogConfiguration: .init(
            supportDirectory: support,
            ttsModelsDirectory: root.appendingPathComponent("tts-models"),
            ttsRuntimeDirectory: root.appendingPathComponent("tts-runtime"),
            defaults: defaults,
            appConfiguration: .init(engineURL: root.appendingPathComponent("nemo-speech"), modelURL: english),
            initialState: .ready
        ))
        coordinator.refreshInstalledSpeechModels()
        let choice = try XCTUnwrap(coordinator.installedSpeechModels.first { $0.url == multilingual })
        coordinator.selectInstalledSpeechModel(choice)

        XCTAssertEqual(coordinator.configuration.modelURL, multilingual)
        XCTAssertEqual(AppConfiguration(environment: [:], defaults: defaults).modelURL, multilingual)
        XCTAssertEqual(coordinator.dictationEngineStatus, .disabled)
        XCTAssertFalse(coordinator.serverManager.isRunning)
    }

    func testOfficialModelFilenamesSelectExpectedLanguageBehavior() {
        let engine = URL(fileURLWithPath: "/engine/nemo-speech")
        let english = AppConfiguration(
            engineURL: engine,
            modelURL: URL(fileURLWithPath: "/models/\(AppConfiguration.modelFileName)"),
            recognitionLanguage: .spanishSpain
        )
        let multilingual = AppConfiguration(
            engineURL: engine,
            modelURL: URL(fileURLWithPath: "/models/\(AppConfiguration.multilingualModelFileName)")
        )

        XCTAssertEqual(english.modelVariant, .english)
        XCTAssertEqual(english.recognitionLanguage, .englishUS)
        XCTAssertFalse(english.modelVariant.supportsLanguageSelection)
        XCTAssertEqual(multilingual.modelVariant, .multilingual)
        XCTAssertEqual(multilingual.recognitionLanguage, .automatic)
        XCTAssertTrue(multilingual.modelVariant.supportsLanguageSelection)
    }

    func testMultilingualLanguagePersistsAndEnvironmentCanOverrideIt() throws {
        let suiteName = "LocalDictationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("/models/\(AppConfiguration.multilingualModelFileName)", forKey: "modelPath")
        defaults.set(RecognitionLanguage.spanishSpain.rawValue, forKey: "recognitionLanguage")

        let persisted = AppConfiguration(environment: [:], defaults: defaults)
        let overridden = AppConfiguration(
            environment: ["LOCAL_DICTATION_LANGUAGE": RecognitionLanguage.spanishUS.rawValue],
            defaults: defaults
        )

        XCTAssertEqual(persisted.recognitionLanguage, .spanishSpain)
        XCTAssertEqual(overridden.recognitionLanguage, .spanishUS)
    }

    func testMultilingualCatalogUsesOfficialModelAndLicenseLinks() {
        XCTAssertEqual(RecognitionLanguage.allCases.count, 33)
        XCTAssertEqual(
            AppConfiguration.multilingualModelPageURL.host,
            "huggingface.co"
        )
        XCTAssertTrue(
            AppConfiguration.multilingualModelDownloadURL.path.hasSuffix(
                AppConfiguration.multilingualModelFileName
            )
        )
        XCTAssertEqual(
            AppConfiguration.multilingualModelLicenseURL.absoluteString,
            "https://openmdw.ai/license/1-1/"
        )
    }

    func testValidExecutableAndGGUFPassValidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = directory.appendingPathComponent("nemo-speech")
        let model = directory.appendingPathComponent("model.gguf")
        try Data("#!/bin/sh\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        try Data("GGUFfixture".utf8).write(to: model)

        let configuration = AppConfiguration(engineURL: engine, modelURL: model)
        XCTAssertNil(configuration.validate())
    }

    func testInstalledSpeechCatalogIncludesOnlyValidCurrentModelWithoutDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("imported.gguf")
        try Data("GGUFfixture".utf8).write(to: valid)
        let models = AppConfiguration.installedSpeechModels(currentModelURL: valid, supportDirectory: directory)
        XCTAssertEqual(models.map(\.url), [valid.standardizedFileURL])
        XCTAssertEqual(AppConfiguration.installedSpeechModels(currentModelURL: directory.appendingPathComponent("partial.gguf"), supportDirectory: directory), [])
    }

    func testRememberedExternalSpeechModelsPersistIndependentlyOfCurrentChoice() throws {
        let suite = "LocalDictationTests.models.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = URL(fileURLWithPath: "/tmp/imported-model.gguf")
        AppConfiguration.rememberSpeechModel(model, defaults: defaults)
        XCTAssertEqual(defaults.array(forKey: "knownSpeechModelPaths") as? [String], [model.path])
    }

    func testMissingEngineIsActionableFirstIssue() {
        let configuration = AppConfiguration(
            engineURL: URL(fileURLWithPath: "/missing/engine"),
            modelURL: URL(fileURLWithPath: "/missing/model.gguf")
        )
        XCTAssertEqual(configuration.validate(), .engineMissing)
        XCTAssertEqual(configuration.validateEngine(), .engineMissing)
        XCTAssertEqual(configuration.validateModel(), .modelMissing)
    }

    func testRejectsFileWithGGUFExtensionButWrongMagic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = directory.appendingPathComponent("nemo-speech")
        let model = directory.appendingPathComponent("model.gguf")
        try Data("#!/bin/sh\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        try Data("NOPE".utf8).write(to: model)

        XCTAssertEqual(
            AppConfiguration(engineURL: engine, modelURL: model).validate(),
            .modelNotGGUF
        )
    }
}
