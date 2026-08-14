import XCTest
@testable import LocalDictation

final class AppConfigurationTests: XCTestCase {
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
