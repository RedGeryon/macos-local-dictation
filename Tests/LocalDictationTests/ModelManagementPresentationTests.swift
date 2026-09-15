import AppKit
import XCTest
@testable import LocalDictation

@MainActor
final class ModelManagementPresentationTests: XCTestCase {
    func testFreshCatalogShowsNoModelsDisablesLoadsAndKeepsAddModelAvailable() throws {
        let fixture = try Fixture()
        let coordinator = fixture.makeCoordinator()
        coordinator.refreshInstalledSpeechModels()
        coordinator.refreshTextToSpeechInstallStatus()

        let content = try modelsContent(for: coordinator)
        let asrPicker = try control("models.asr.model", in: content, as: NSPopUpButton.self)
        let ttsPicker = try control("models.tts.model", in: content, as: NSPopUpButton.self)

        XCTAssertEqual(asrPicker.itemTitles, ["No models downloaded"])
        XCTAssertFalse(asrPicker.isEnabled)
        XCTAssertEqual(ttsPicker.itemTitles, ["No models downloaded"])
        XCTAssertFalse(ttsPicker.isEnabled)
        XCTAssertTrue(try control("models.asr.add", in: content, as: NSButton.self).isEnabled)
        XCTAssertTrue(try control("models.tts.add", in: content, as: NSButton.self).isEnabled)
        XCTAssertFalse(try control("models.asr.load", in: content, as: NSButton.self).isEnabled)
        XCTAssertFalse(try control("models.tts.load", in: content, as: NSButton.self).isEnabled)
    }

    func testEightBitOnlyDoesNotPretendThatSavedBF16SelectionIsInstalled() throws {
        let fixture = try Fixture(selectedTTSModel: .bf16)
        try fixture.installTTSComponent("customvoice", model: .eightBit)
        let coordinator = fixture.makeCoordinator()
        coordinator.refreshTextToSpeechInstallStatus()

        let content = try modelsContent(for: coordinator)
        let picker = try control("models.tts.model", in: content, as: NSPopUpButton.self)

        XCTAssertEqual(picker.itemTitles, ["Qwen 1.7B (8-bit)", "Select a model…"])
        XCTAssertEqual(picker.titleOfSelectedItem, "Select a model…")
        XCTAssertTrue(picker.isEnabled)
        XCTAssertFalse(picker.itemTitles.contains("Qwen 1.7B (BF16)"))
        XCTAssertTrue(try control("models.tts.add", in: content, as: NSButton.self).isEnabled)
    }

    func testSelectingOnlyInstalledEightBitFamilyUpdatesOnlyInjectedSettings() throws {
        let fixture = try Fixture(selectedTTSModel: .bf16)
        try fixture.installTTSComponent("customvoice", model: .eightBit)
        let coordinator = fixture.makeCoordinator()
        coordinator.refreshTextToSpeechInstallStatus()
        let rendered = try modelsView(for: coordinator)
        let picker = try control("models.tts.model", in: rendered.content, as: NSPopUpButton.self)

        picker.selectItem(at: 0)
        let target = try XCTUnwrap(picker.target as? NSObject)
        _ = target.perform(try XCTUnwrap(picker.action), with: picker)

        XCTAssertEqual(coordinator.localFeatureSettings.readAloud.model, .eightBit)
        XCTAssertEqual(LocalFeatureSettings.load(defaults: fixture.defaults).readAloud.model, .eightBit)
        XCTAssertEqual(coordinator.readAloudEngineStatus, .notLoaded)
        guard case .unavailable = coordinator.textToSpeechState else {
            return XCTFail("Weights without the Read Aloud runtime must show setup guidance, not try to load.")
        }
    }

    func testInstalledPickersOnlyListVerifiedModelsAndKeepChosenFamiliesSelected() throws {
        let fixture = try Fixture(
            selectedTTSModel: .eightBit,
            currentSpeechModelName: AppConfiguration.multilingualModelFileName
        )
        try fixture.installSpeechModel(named: AppConfiguration.modelFileName)
        try fixture.installSpeechModel(named: AppConfiguration.multilingualModelFileName)
        try fixture.installTTSComponent("customvoice", model: .bf16)
        try fixture.installTTSComponent("customvoice", model: .eightBit)
        let coordinator = fixture.makeCoordinator()
        coordinator.refreshInstalledSpeechModels()
        coordinator.refreshTextToSpeechInstallStatus()

        let content = try modelsContent(for: coordinator)
        let asrPicker = try control("models.asr.model", in: content, as: NSPopUpButton.self)
        let ttsPicker = try control("models.tts.model", in: content, as: NSPopUpButton.self)

        XCTAssertEqual(asrPicker.itemTitles, ["English streaming model", "Multilingual streaming model"])
        XCTAssertEqual(asrPicker.titleOfSelectedItem, "Multilingual streaming model")
        XCTAssertEqual(ttsPicker.itemTitles, ["Qwen 1.7B (BF16)", "Qwen 1.7B (8-bit)"])
        XCTAssertEqual(ttsPicker.titleOfSelectedItem, "Qwen 1.7B (8-bit)")
    }

    func testCatalogRowsUseTheSameAccessibleInfoAndDownloadPattern() throws {
        let asr = ModelCatalogPopover(items: [
            .init(title: "English dictation (Q8)", detail: "Fast local transcription for English.", installed: false, add: {}),
            .init(title: "Multilingual dictation (Q8)", detail: "Local transcription for multiple languages.", installed: false, add: {})
        ], importAction: {})
        let tts = ModelCatalogPopover(items: [
            .init(title: "Qwen 1.7B • BF16", detail: "Higher-precision local voice-model family.", installed: false, add: {}),
            .init(title: "Qwen 1.7B • 8-bit", detail: "Smaller local voice-model family.", installed: false, add: {})
        ])

        for (catalog, hasImport) in [(asr, true), (tts, false)] {
            _ = catalog.view
            for index in 0...1 {
                let info = try control("catalog.info.\(index)", in: catalog.view, as: NSButton.self)
                XCTAssertFalse(info.accessibilityLabel()?.isEmpty ?? true)
                XCTAssertFalse(info.toolTip?.isEmpty ?? true)
                XCTAssertNotNil(info.target)
                XCTAssertNotNil(info.action)
                let download = try control("catalog.add.\(index)", in: catalog.view, as: NSButton.self)
                XCTAssertEqual(download.title, "Download")
                XCTAssertTrue(download.isEnabled)
            }
            XCTAssertEqual(find("catalog.import", in: catalog.view) != nil, hasImport)
        }
    }

    func testInfoPopoverHasReadableWidthAndMeasuredTextHeight() throws {
        let detail = "Qwen CustomVoice 8-bit is quantized for MLX, the Apple Silicon model runtime, and includes the preset Ryan and Aiden voices. It uses less download space and memory, with possible subtle voice-quality differences from BF16."
        let popover = ModelCatalogPopover.makeInfoPopover(detail: detail)
        let body = try XCTUnwrap(popover.contentViewController?.view)
        body.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(popover.contentSize.width, 328)
        XCTAssertGreaterThanOrEqual(body.fittingSize.width, 328)
        XCTAssertGreaterThan(popover.contentSize.height, 50)
        XCTAssertGreaterThan(body.fittingSize.height, 50)
    }

    func testEmbeddedTTSComponentInfoButtonsRemainAvailableForInstalledComponents() throws {
        let fresh = try Fixture()
        let freshCoordinator = fresh.makeCoordinator()
        freshCoordinator.refreshTextToSpeechInstallStatus()
        let freshRendered = try modelsView(for: freshCoordinator)
        XCTAssertInfoButton("info.Preset voices", in: freshRendered.content)
        try press(try control("models.tts.customDisclosure", in: freshRendered.content, as: NSButton.self))
        let freshContent = try content(of: freshRendered.controller)
        XCTAssertInfoButton("info.Voice Design", in: freshContent)
        XCTAssertInfoButton("info.Voice Replay", in: freshContent)

        let installed = try Fixture()
        try installed.installTTSComponent("customvoice", model: .bf16)
        try installed.installTTSComponent("voicedesign", model: .bf16)
        try installed.installTTSComponent("base", model: .bf16)
        let installedCoordinator = installed.makeCoordinator()
        installedCoordinator.refreshTextToSpeechInstallStatus()
        let installedRendered = try modelsView(for: installedCoordinator)
        XCTAssertInfoButton("info.Preset voices", in: installedRendered.content)
        try press(try control("models.tts.customDisclosure", in: installedRendered.content, as: NSButton.self))
        let installedContent = try content(of: installedRendered.controller)
        XCTAssertInfoButton("info.Voice Design", in: installedContent)
        XCTAssertInfoButton("info.Voice Replay", in: installedContent)
    }

    func testStorageShowsPathsAndRemovalControlsAndDeletesOnlyChosenComponent() throws {
        let fixture = try Fixture()
        try fixture.installSpeechModel(named: AppConfiguration.modelFileName)
        try fixture.installTTSComponent("customvoice", model: .bf16)
        try fixture.installTTSComponent("base", model: .eightBit)
        let coordinator = fixture.makeCoordinator()
        coordinator.refreshInstalledSpeechModels()
        let content = try modelsContent(for: coordinator)
        XCTAssertTrue(try control("models.storage.removeAll", in: content, as: NSButton.self).isEnabled)
        XCTAssertEqual(coordinator.storedModels.count, 3)
        for index in 0..<3 {
            XCTAssertFalse(try control("models.storage.path.\(index)", in: content, as: NSTextField.self).stringValue.isEmpty)
            XCTAssertTrue(try control("models.storage.remove.\(index)", in: content, as: NSButton.self).isEnabled)
        }
        let component = try XCTUnwrap(coordinator.storedModels.first { $0.url.lastPathComponent.contains("base-8bit") })
        try coordinator.removeStoredModel(component, move: { try FileManager.default.removeItem(at: $0) })
        XCTAssertEqual(coordinator.storedModels.count, 2)
        XCTAssertEqual(coordinator.installedSpeechModels.count, 1)
        XCTAssertTrue(coordinator.textToSpeechModelInstallStatus.customVoiceInstalled)
    }

    func testDeletingSelectedSpeechModelKeepsOtherDownloadsAndRequiresASelection() throws {
        let fixture = try Fixture()
        try fixture.installSpeechModel(named: AppConfiguration.modelFileName)
        try fixture.installSpeechModel(named: AppConfiguration.multilingualModelFileName)
        let coordinator = fixture.makeCoordinator()
        coordinator.refreshInstalledSpeechModels()
        let selected = try XCTUnwrap(coordinator.storedModels.first { $0.url.lastPathComponent == AppConfiguration.modelFileName })
        try coordinator.removeStoredModel(selected, move: { try FileManager.default.removeItem(at: $0) })
        XCTAssertEqual(coordinator.state, .configurationRequired(.modelMissing))
        XCTAssertEqual(coordinator.installedSpeechModels.map(\.variant), [.multilingual])
        XCTAssertEqual(coordinator.dictationEngineStatus, .notLoaded)
        XCTAssertFalse(coordinator.canRemoveModels, "Wait for the existing unload task before allowing another removal.")
    }

    private func modelsContent(for coordinator: AppCoordinator) throws -> NSView {
        try modelsView(for: coordinator).content
    }

    private func modelsView(for coordinator: AppCoordinator) throws -> (controller: UnifiedLocalDictationWindowController, content: NSView) {
        _ = NSApplication.shared
        let controller = UnifiedLocalDictationWindowController(coordinator: coordinator)
        controller.showModels()
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        return (controller, try XCTUnwrap(find("unified.content", in: window.contentView)))
    }

    private func content(of controller: UnifiedLocalDictationWindowController) throws -> NSView {
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        return try XCTUnwrap(find("unified.content", in: window.contentView))
    }

    private func press(_ button: NSButton) throws {
        let target = try XCTUnwrap(button.target as? NSObject)
        _ = target.perform(try XCTUnwrap(button.action), with: button)
    }

    private func XCTAssertInfoButton(_ identifier: String, in root: NSView, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = find(identifier, in: root) as? NSButton else {
            XCTFail("Missing \(identifier)", file: file, line: line)
            return
        }
        XCTAssertFalse(button.isHidden, file: file, line: line)
        XCTAssertGreaterThan(button.bounds.width, 0, file: file, line: line)
        XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true, file: file, line: line)
        XCTAssertFalse(button.toolTip?.isEmpty ?? true, file: file, line: line)
        XCTAssertNotNil(button.target, file: file, line: line)
        XCTAssertNotNil(button.action, file: file, line: line)
    }

    private func control<T: NSView>(_ id: String, in root: NSView, as type: T.Type) throws -> T {
        try XCTUnwrap(find(id, in: root) as? T, "Missing \(id)")
    }

    private func find(_ id: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }

    private final class Fixture {
        let root: URL
        let support: URL
        let models: URL
        let runtime: URL
        let defaults: UserDefaults
        let suiteName: String
        let currentSpeechModelName: String

        init(
            selectedTTSModel: TextToSpeechModelChoice = .bf16,
            currentSpeechModelName: String = AppConfiguration.modelFileName
        ) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDictation-ModelPresentation-\(UUID().uuidString)", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            models = root.appendingPathComponent("tts-models", isDirectory: true)
            runtime = root.appendingPathComponent("tts-runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: support.appendingPathComponent("Models", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
            suiteName = "LocalDictationTests.ModelManagementPresentation.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            self.currentSpeechModelName = currentSpeechModelName
            let settings = LocalFeatureSettings(
                dictation: .init(enabled: true, loadAtStartup: false),
                readAloud: .init(enabled: true, loadAtStartup: false, model: selectedTTSModel)
            )
            settings.persist(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        @MainActor func makeCoordinator() -> AppCoordinator {
            let modelURL = support.appendingPathComponent("Models/\(currentSpeechModelName)")
            return AppCoordinator(modelCatalogConfiguration: .init(
                supportDirectory: support,
                ttsModelsDirectory: models,
                ttsRuntimeDirectory: runtime,
                defaults: defaults,
                appConfiguration: .init(
                    engineURL: support.appendingPathComponent("nemo-speech"),
                    modelURL: modelURL,
                    recognitionLanguage: SpeechModelVariant.identify(modelURL).recommendedLanguage
                ),
                initialState: .configurationRequired(.modelMissing)
            ))
        }

        func installSpeechModel(named name: String) throws {
            try Data("GGUFfixture".utf8).write(to: support.appendingPathComponent("Models/\(name)"))
        }

        func installTTSComponent(_ component: String, model: TextToSpeechModelChoice) throws {
            let pin: (repository: String, revision: String)
            switch (component, model) {
            case ("customvoice", .bf16): pin = ("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", "52f4770fd9726457eae3d3b6aa92047a25a10776")
            case ("customvoice", .eightBit): pin = ("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit", "41d3337e8b7f2843a75841595fc14e4b9a7a4b96")
            case ("voicedesign", .bf16): pin = ("mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", "7d3824abff87e49756bb0f83fb5411de75d160c4")
            case ("voicedesign", .eightBit): pin = ("mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit", "f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee")
            case ("base", .bf16): pin = ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "a6eb4f68e4b056f1215157bb696209bc82a6db48")
            case ("base", .eightBit): pin = ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", "e7dd0585652209fa0d7783659aad4e8a324de11c")
            default: fatalError("Unknown fixture component.")
            }
            let precision = model == .bf16 ? "bf16" : "8bit"
            let directory = models.appendingPathComponent("qwen3-tts-1.7b-\(component)-\(precision)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("speech_tokenizer", isDirectory: true), withIntermediateDirectories: true)
            let marker = try JSONSerialization.data(withJSONObject: ["repository": pin.repository, "revision": pin.revision])
            try marker.write(to: directory.appendingPathComponent(".local-dictation-complete.json"))
            for name in ["config.json", "tokenizer_config.json", "vocab.json", "merges.txt", "weights.safetensors"] {
                try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
