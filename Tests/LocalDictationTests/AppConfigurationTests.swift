import XCTest
@testable import LocalDictation

final class AppConfigurationTests: XCTestCase {
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
