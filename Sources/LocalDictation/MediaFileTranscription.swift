import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct MediaFileInformation: Equatable, Sendable {
    let fileURL: URL
    let duration: TimeInterval
    let formatLabel: String
    let containsVideo: Bool
    let fileByteCount: Int64
}

enum MediaFileTranscriptionProgress: Equatable, Sendable {
    case decoding(Double)
    case recognizing
}

enum MediaFileTranscriptionError: LocalizedError {
    case unreadableMedia
    case noAudioTrack
    case invalidDuration
    case tooLong(TimeInterval)
    case conversionFailed(String)
    case uploadTooLarge
    case server(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .unreadableMedia:
            return "macOS could not read this audio or video file."
        case .noAudioTrack:
            return "The selected file does not contain a readable audio track."
        case .invalidDuration:
            return "The selected file does not report a valid duration."
        case .tooLong(let maximumDuration):
            return "This file is longer than the supported \(Self.duration(maximumDuration)) per transcription job."
        case .conversionFailed(let detail):
            return "The audio track could not be prepared for transcription: \(detail)"
        case .uploadTooLarge:
            return "The prepared audio exceeds the local engine's 512 MB request limit."
        case .server(let detail):
            return "The speech engine could not transcribe this file: \(detail)"
        case .emptyTranscript:
            return "The file was processed, but no speech was detected."
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let hours = max(1, Int(seconds / 3_600))
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}

struct MediaFileTranscriptionEstimator {
    static let defaultRealTimeFactor = 0.04 // Conservative 25× real time.
    static let fixedOverheadSeconds: TimeInterval = 2
    static let minimumEstimateSeconds: TimeInterval = 3

    private let defaults: UserDefaults
    private let key: String
    private(set) var realTimeFactor: Double

    init(modelVariant: SpeechModelVariant, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "mediaFileTranscriptionRealTimeFactor.\(modelVariant.rawValue)"
        let saved = defaults.double(forKey: key)
        realTimeFactor = saved > 0 ? Self.clamped(saved) : Self.defaultRealTimeFactor
    }

    func estimatedSeconds(for duration: TimeInterval) -> TimeInterval {
        max(
            Self.minimumEstimateSeconds,
            Self.fixedOverheadSeconds + max(0, duration) * realTimeFactor
        )
    }

    mutating func record(duration: TimeInterval, elapsed: TimeInterval) {
        guard duration > 0, elapsed > 0 else { return }
        let observed = Self.clamped(max(0, elapsed - Self.fixedOverheadSeconds) / duration)
        realTimeFactor = Self.clamped((realTimeFactor * 0.65) + (observed * 0.35))
        defaults.set(realTimeFactor, forKey: key)
    }

    static func readableEstimate(_ seconds: TimeInterval) -> String {
        let rounded = max(1, Int(seconds.rounded(.up)))
        if rounded < 60 { return "about \(rounded) seconds" }
        let minutes = Int(ceil(Double(rounded) / 60))
        if minutes < 60 { return "about \(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = Double(minutes) / 60
        return String(format: "about %.1f hours", hours)
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0.005, value))
    }
}

struct MediaTranscriptDocument {
    static func directory(fileManager: FileManager = .default) throws -> URL {
        let directory = try TranscriptStorage.directory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func outputURL(
        for sourceURL: URL,
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try TranscriptStorage.dailyDirectory(at: date, fileManager: fileManager)
        let rawName = sourceURL.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(rawName.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = String((cleaned.isEmpty ? "Media" : cleaned).prefix(80))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let datedName = "\(baseName) Transcript \(formatter.string(from: date))"
        var candidate = directory.appendingPathComponent(datedName).appendingPathExtension("txt")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(datedName) (\(suffix))")
                .appendingPathExtension("txt")
            suffix += 1
        }
        return candidate
    }

    static func write(
        transcript: String,
        source: MediaFileInformation,
        modelName: String,
        language: RecognitionLanguage,
        to outputURL: URL,
        completedAt: Date = Date()
    ) throws {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        let document = """
        File Transcript
        Source: \(source.fileURL.lastPathComponent)
        Duration: \(readableDuration(source.duration))
        Model: \(modelName)
        Language: \(language.title)
        Completed: \(formatter.string(from: completedAt))

        \(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        try Data(document.utf8).write(to: outputURL, options: .atomic)
    }

    static func readableDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

final class MediaFileTranscriptionService: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (MediaFileTranscriptionProgress) -> Void

    static let maximumDuration: TimeInterval = 4 * 60 * 60
    static let maximumUploadBytes = 500_000_000
    static let supportedFormatsDescription = "Audio: WAV, MP3, M4A/ALAC, AAC, CAF, AIFF, FLAC. Video with an audio track: MP4, M4V, MOV. Maximum length: 4 hours."
    static let selectableContentTypes: [UTType] = [.audio, .movie]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        Self.removeStaleTemporaryUploads()
    }

    func inspect(_ fileURL: URL) async throws -> MediaFileInformation {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: fileURL)
            let durationTime: CMTime
            let audioTracks: [AVAssetTrack]
            let videoTracks: [AVAssetTrack]
            do {
                durationTime = try await asset.load(.duration)
                async let loadedAudio = asset.loadTracks(withMediaType: .audio)
                async let loadedVideo = asset.loadTracks(withMediaType: .video)
                audioTracks = try await loadedAudio
                videoTracks = try await loadedVideo
            } catch {
                throw MediaFileTranscriptionError.unreadableMedia
            }
            guard !audioTracks.isEmpty else { throw MediaFileTranscriptionError.noAudioTrack }
            let duration = durationTime.seconds
            guard duration.isFinite, duration > 0 else {
                throw MediaFileTranscriptionError.invalidDuration
            }
            guard duration <= Self.maximumDuration else {
                throw MediaFileTranscriptionError.tooLong(Self.maximumDuration)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let fileExtension = fileURL.pathExtension.uppercased()
            return MediaFileInformation(
                fileURL: fileURL,
                duration: duration,
                formatLabel: fileExtension.isEmpty ? "Media" : fileExtension,
                containsVideo: !videoTracks.isEmpty,
                fileByteCount: byteCount
            )
        }.value
    }

    func transcribe(
        _ information: MediaFileInformation,
        endpoint: URL,
        language: RecognitionLanguage,
        progress: @escaping ProgressHandler
    ) async throws -> String {
        let body = try await Self.makeMultipartUpload(
            information: information,
            language: language,
            progress: progress
        )
        defer { try? FileManager.default.removeItem(at: body.fileURL) }
        try Task.checkCancellation()
        progress(.recognizing)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(120, information.duration)
        request.setValue(
            "multipart/form-data; boundary=\(body.boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        let (data, response) = try await session.upload(for: request, fromFile: body.fileURL)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw MediaFileTranscriptionError.server("The local server returned no HTTP response.")
        }
        let responseText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw MediaFileTranscriptionError.server(
                responseText.isEmpty ? "HTTP \(http.statusCode)" : responseText
            )
        }
        guard !responseText.isEmpty else { throw MediaFileTranscriptionError.emptyTranscript }
        return responseText
    }

    struct MultipartUpload: Sendable {
        let fileURL: URL
        let boundary: String
    }

    static func makeMultipartUpload(
        information: MediaFileInformation,
        language: RecognitionLanguage,
        progress: @escaping ProgressHandler
    ) async throws -> MultipartUpload {
        try await Task.detached(priority: .userInitiated) {
            let boundary = "LocalDictation-\(UUID().uuidString)"
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalDictation-\(UUID().uuidString).upload")
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }

            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                let preamble = Data((
                    "--\(boundary)\r\n"
                        + "Content-Disposition: form-data; name=\"file\"; filename=\"media.wav\"\r\n"
                        + "Content-Type: audio/wav\r\n\r\n"
                ).utf8)
                try handle.write(contentsOf: preamble)
                let wavHeaderOffset = try handle.offset()
                try handle.write(contentsOf: Data(count: 44))

                let asset = AVURLAsset(url: information.fileURL)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard let track = tracks.first else { throw MediaFileTranscriptionError.noAudioTrack }
                let reader = try AVAssetReader(asset: asset)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    throw MediaFileTranscriptionError.conversionFailed("macOS rejected the audio conversion settings.")
                }
                reader.add(output)
                guard reader.startReading() else {
                    throw MediaFileTranscriptionError.conversionFailed(
                        reader.error?.localizedDescription ?? "The media reader could not start."
                    )
                }

                var pcmByteCount = 0
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    guard pcmByteCount + length <= Self.maximumUploadBytes else {
                        reader.cancelReading()
                        throw MediaFileTranscriptionError.uploadTooLarge
                    }
                    var bytes = Data(count: length)
                    let status = bytes.withUnsafeMutableBytes { storage in
                        guard let baseAddress = storage.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
                        return CMBlockBufferCopyDataBytes(
                            block,
                            atOffset: 0,
                            dataLength: length,
                            destination: baseAddress
                        )
                    }
                    guard status == kCMBlockBufferNoErr else {
                        reader.cancelReading()
                        throw MediaFileTranscriptionError.conversionFailed("macOS could not read an audio sample.")
                    }
                    try handle.write(contentsOf: bytes)
                    pcmByteCount += length
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if timestamp.isFinite {
                        progress(.decoding(min(1, max(0, timestamp / information.duration))))
                    }
                }

                guard reader.status == .completed else {
                    throw MediaFileTranscriptionError.conversionFailed(
                        reader.error?.localizedDescription ?? "The audio conversion stopped early."
                    )
                }
                guard pcmByteCount > 0 else { throw MediaFileTranscriptionError.noAudioTrack }

                let endOfPCM = try handle.offset()
                try handle.seek(toOffset: wavHeaderOffset)
                try handle.write(contentsOf: try wavHeader(pcmByteCount: pcmByteCount))
                try handle.seek(toOffset: endOfPCM)
                let languageField = language.rawValue
                let closing = Data((
                    "\r\n--\(boundary)\r\n"
                        + "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n"
                        + "text\r\n"
                        + "--\(boundary)\r\n"
                        + "Content-Disposition: form-data; name=\"language\"\r\n\r\n"
                        + "\(languageField)\r\n"
                        + "--\(boundary)--\r\n"
                ).utf8)
                try handle.write(contentsOf: closing)
                progress(.decoding(1))
                return MultipartUpload(fileURL: fileURL, boundary: boundary)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        }.value
    }

    static func wavHeader(pcmByteCount: Int) throws -> Data {
        guard pcmByteCount >= 0, pcmByteCount <= Int(UInt32.max) - 36 else {
            throw MediaFileTranscriptionError.uploadTooLarge
        }
        var data = Data()
        data.append(Data("RIFF".utf8))
        append(UInt32(36 + pcmByteCount), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(16_000), to: &data)
        append(UInt32(32_000), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(pcmByteCount), to: &data)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func removeStaleTemporaryUploads(fileManager: FileManager = .default) {
        let directory = fileManager.temporaryDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("LocalDictation-")
            && file.pathExtension == "upload" {
            try? fileManager.removeItem(at: file)
        }
    }
}
