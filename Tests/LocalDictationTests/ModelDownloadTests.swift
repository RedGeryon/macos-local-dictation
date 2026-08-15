import CryptoKit
import XCTest
@testable import LocalDictation

final class ModelDownloadTests: XCTestCase {
    private final class DownloadURLProtocol: URLProtocol, @unchecked Sendable {
        static let payload = Data("GGUFnetwork-fixture".utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(Self.payload.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testOfficialMultilingualDownloadIsPinnedAndStoredInApplicationSupport() {
        let specification = SpeechModelDownloadSpecification.multilingual

        XCTAssertEqual(specification.variant, .multilingual)
        XCTAssertEqual(specification.expectedBytes, 741_548_352)
        XCTAssertEqual(
            specification.sha256,
            "a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae"
        )
        XCTAssertTrue(specification.sourceURL.absoluteString.contains("/resolve/1c8deaecc64b91f034d73e08dd8b64625eb3395d/"))
        XCTAssertTrue(specification.destinationURL.path.hasSuffix("/Models/\(AppConfiguration.multilingualModelFileName)"))
    }

    func testVerifierAcceptsMatchingGGUFAndRejectsChecksumMismatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("fixture.gguf")
        let data = Data("GGUFfixture".utf8)
        try data.write(to: fileURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let valid = SpeechModelDownloadSpecification(
            variant: .custom,
            title: "Fixture",
            fileName: fileURL.lastPathComponent,
            sourceURL: URL(string: "https://example.invalid/fixture.gguf")!,
            licenseURL: URL(string: "https://example.invalid/license")!,
            expectedBytes: Int64(data.count),
            sha256: digest
        )

        XCTAssertNoThrow(
            try ModelDownloader.verifyModel(at: fileURL, specification: valid)
        )

        let invalid = SpeechModelDownloadSpecification(
            variant: .custom,
            title: "Fixture",
            fileName: fileURL.lastPathComponent,
            sourceURL: valid.sourceURL,
            licenseURL: valid.licenseURL,
            expectedBytes: Int64(data.count),
            sha256: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(
            try ModelDownloader.verifyModel(at: fileURL, specification: invalid)
        ) { error in
            guard case ModelDownloadError.checksumMismatch = error else {
                return XCTFail("Expected checksum mismatch, got \(error)")
            }
        }
    }

    func testDownloadStateReportsActiveTransferOnlyWhileDownloading() {
        let specification = SpeechModelDownloadSpecification.multilingual
        XCTAssertFalse(ModelDownloadState.idle.isDownloading)
        XCTAssertTrue(
            ModelDownloadState.downloading(
                specification: specification,
                receivedBytes: 10,
                totalBytes: 100
            ).isDownloading
        )
        XCTAssertFalse(
            ModelDownloadState.completed(
                specification: specification,
                fileURL: specification.destinationURL
            ).isDownloading
        )
    }

    func testNativeDownloaderProducesAStagedFileWithoutOpeningABrowser() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadURLProtocol.self]
        let downloader = ModelDownloader(configuration: configuration)
        let fileName = "network-fixture-\(UUID().uuidString).gguf"
        let payload = DownloadURLProtocol.payload
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let specification = SpeechModelDownloadSpecification(
            variant: .custom,
            title: "Network fixture",
            fileName: fileName,
            sourceURL: URL(string: "https://example.invalid/\(fileName)")!,
            licenseURL: URL(string: "https://example.invalid/license")!,
            expectedBytes: Int64(payload.count),
            sha256: digest
        )
        let stagedURL = try await downloader.download(specification) { _, _ in }
        defer {
            try? FileManager.default.removeItem(at: stagedURL)
            try? FileManager.default.removeItem(at: specification.destinationURL)
        }

        XCTAssertEqual(try Data(contentsOf: stagedURL), payload)
        let installedURL = try ModelDownloader.installVerifiedModel(
            from: stagedURL,
            specification: specification
        )
        XCTAssertEqual(installedURL, specification.destinationURL)
        XCTAssertEqual(try Data(contentsOf: installedURL), payload)
    }
}
