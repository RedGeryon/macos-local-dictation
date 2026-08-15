import CryptoKit
import Foundation

struct SpeechModelDownloadSpecification: Equatable, Sendable {
    let variant: SpeechModelVariant
    let title: String
    let fileName: String
    let sourceURL: URL
    let licenseURL: URL
    let expectedBytes: Int64
    let sha256: String

    var destinationURL: URL {
        AppConfiguration.supportDirectory()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static let english = SpeechModelDownloadSpecification(
        variant: .english,
        title: "English 0.6B Q8",
        fileName: AppConfiguration.modelFileName,
        sourceURL: AppConfiguration.englishModelDownloadURL,
        licenseURL: AppConfiguration.englishModelLicenseURL,
        expectedBytes: 699_872_960,
        sha256: "d9a01898d2a611c8764e23a1c2f45e70bbd5a425dc4de93692ac951dd603812d"
    )

    static let multilingual = SpeechModelDownloadSpecification(
        variant: .multilingual,
        title: "Multilingual 0.6B Q8",
        fileName: AppConfiguration.multilingualModelFileName,
        sourceURL: AppConfiguration.multilingualModelDownloadURL,
        licenseURL: AppConfiguration.multilingualModelLicenseURL,
        expectedBytes: 741_548_352,
        sha256: "a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae"
    )
}

enum ModelDownloadState: Equatable, Sendable {
    case idle
    case downloading(
        specification: SpeechModelDownloadSpecification,
        receivedBytes: Int64,
        totalBytes: Int64
    )
    case completed(specification: SpeechModelDownloadSpecification, fileURL: URL)
    case failed(specification: SpeechModelDownloadSpecification, message: String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

enum ModelDownloadError: LocalizedError {
    case invalidHTTPResponse(Int)
    case unexpectedFileSize(expected: Int64, actual: Int64)
    case checksumMismatch
    case invalidGGUF
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse(let status):
            return "The model host returned HTTP \(status). Try again later."
        case .unexpectedFileSize(let expected, let actual):
            return "The downloaded file size was unexpected (\(actual) instead of \(expected) bytes)."
        case .checksumMismatch:
            return "The model checksum did not match NVIDIA’s published file. The download was discarded."
        case .invalidGGUF:
            return "The downloaded file is not a valid GGUF model. The download was discarded."
        case .incompleteDownload:
            return "The model download ended before a complete file was available."
        }
    }
}

final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (Int64, Int64) -> Void

    private let lock = NSLock()
    private let sessionConfiguration: URLSessionConfiguration
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.localdictation.model-download"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private lazy var session = URLSession(
        configuration: sessionConfiguration,
        delegate: self,
        delegateQueue: delegateQueue
    )
    private var activeTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destinationURL: URL?
    private var completedURL: URL?
    private var terminalError: Error?
    private var progressHandler: ProgressHandler?

    override convenience init() {
        self.init(configuration: .ephemeral)
    }

    init(configuration: URLSessionConfiguration) {
        sessionConfiguration = configuration
        super.init()
    }

    func download(
        _ specification: SpeechModelDownloadSpecification,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                precondition(activeTask == nil, "Only one model download can run at a time")
                self.continuation = continuation
                destinationURL = specification.destinationURL
                completedURL = nil
                terminalError = nil
                progressHandler = progress
                let task = session.downloadTask(with: specification.sourceURL)
                activeTask = task
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = activeTask
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let progress = progressHandler
        lock.unlock()
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw ModelDownloadError.invalidHTTPResponse(response.statusCode)
            }
            guard let destinationURL else { throw ModelDownloadError.incompleteDownload }
            let fileManager = FileManager.default
            let modelDirectory = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            let stagedURL = modelDirectory.appendingPathComponent(".download-\(destinationURL.lastPathComponent)")
            if fileManager.fileExists(atPath: stagedURL.path) {
                try fileManager.removeItem(at: stagedURL)
            }
            try fileManager.moveItem(at: location, to: stagedURL)
            lock.lock()
            completedURL = stagedURL
            lock.unlock()
        } catch {
            lock.lock()
            terminalError = error
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let continuation = continuation
        let downloadedURL = completedURL
        let storedError = terminalError
        self.continuation = nil
        activeTask = nil
        destinationURL = nil
        completedURL = nil
        terminalError = nil
        progressHandler = nil
        lock.unlock()

        if let error {
            if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
            continuation?.resume(throwing: error)
        } else if let storedError {
            if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
            continuation?.resume(throwing: storedError)
        } else if let downloadedURL {
            continuation?.resume(returning: downloadedURL)
        } else {
            continuation?.resume(throwing: ModelDownloadError.incompleteDownload)
        }
    }

    static func installVerifiedModel(
        from stagedURL: URL,
        specification: SpeechModelDownloadSpecification,
        fileManager: FileManager = .default
    ) throws -> URL {
        defer { try? fileManager.removeItem(at: stagedURL) }
        try verifyModel(at: stagedURL, specification: specification, fileManager: fileManager)

        let destinationURL = specification.destinationURL
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
        return destinationURL
    }

    static func verifyModel(
        at fileURL: URL,
        specification: SpeechModelDownloadSpecification,
        fileManager: FileManager = .default
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard actualBytes == specification.expectedBytes else {
            throw ModelDownloadError.unexpectedFileSize(
                expected: specification.expectedBytes,
                actual: actualBytes
            )
        }
        guard try sha256(of: fileURL) == specification.sha256 else {
            throw ModelDownloadError.checksumMismatch
        }
        guard AppConfiguration.isGGUF(fileURL) else {
            throw ModelDownloadError.invalidGGUF
        }
    }

    private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
