@preconcurrency import AVFoundation
import Foundation
import OSLog

enum ConversationTranscriptionError: LocalizedError {
    case connectionTimedOut
    case stoppedBeforeReady

    var errorDescription: String? {
        switch self {
        case .connectionTimedOut:
            return "The two local transcription streams did not become ready in time."
        case .stoppedBeforeReady:
            return "Conversation transcription stopped before it became ready."
        }
    }
}

@MainActor
final class ConversationTranscriptionSession {
    typealias PreviewHandler = @MainActor (ConversationSpeaker, String) -> Void
    typealias ErrorHandler = @MainActor (Error) -> Void

    private struct TimedSpeakerSegment {
        let text: String
        let date: Date
    }

    private struct PendingMicrophoneSegment {
        var text: String
        let date: Date
        let startTime: TimeInterval
        let endTime: TimeInterval
        let task: Task<Void, Never>
    }

    private let microphoneClient = RealtimeTranscriptionClient()
    private let speakerClient = RealtimeTranscriptionClient()
    private let microphoneCapture = AudioCaptureService()
    private let systemAudioCapture = SystemAudioCaptureService()
    private let logger = Logger(subsystem: "org.localdictation.app", category: "Conversation")
    private static let stopTailCaptureMilliseconds = 900
    private var writer: ConversationTranscriptWriter?
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuations: [CheckedContinuation<URL, Error>] = []
    private var microphoneConnected = false
    private var speakerConnected = false
    private var microphoneFinal: String?
    private var speakerFinal: String?
    private var recognizedSegments: [ConversationSpeaker: [String]] = [:]
    private var transcriptEntries: [ConversationTranscriptEntry] = []
    private var nextEntrySequence = 0
    private var recentSpeakerSegments: [TimedSpeakerSegment] = []
    private var pendingMicrophoneSegments: [UUID: PendingMicrophoneSegment] = [:]
    private var suppressedMicrophoneEchoSegments = 0
    private var unifiedCapture = false
    private var stopping = false
    private var connectionTimeoutTask: Task<Void, Never>?
    private var finalizationTimeoutTask: Task<Void, Never>?

    var onPreview: PreviewHandler?
    var onError: ErrorHandler?
    private(set) var transcriptURL: URL?

    func start(realtimeURL: URL, automaticPunctuation: Bool) async throws -> URL {
        configureCallbacks()
        systemAudioCapture.onError = { [weak self] error in
            Task { @MainActor [weak self] in self?.handleError(error) }
        }
        microphoneClient.connect(
            to: realtimeURL,
            automaticPunctuation: automaticPunctuation,
            wordTimestamps: true,
            endpointingMilliseconds: 800
        )
        speakerClient.connect(
            to: realtimeURL,
            automaticPunctuation: automaticPunctuation,
            wordTimestamps: true,
            endpointingMilliseconds: 800
        )
        try await waitForConnections()

        microphoneClient.beginUtterance()
        speakerClient.beginUtterance()
        let microphoneName = AVCaptureDevice.default(for: .audio)?.localizedName
        let writer = try ConversationTranscriptWriter(microphoneName: microphoneName)
        self.writer = writer
        transcriptURL = writer.fileURL
        do {
            if #available(macOS 15.0, *) {
                // One ScreenCaptureKit stream owns both sources and releases
                // them atomically. This avoids competing Core Audio clients
                // leaving AirPods in their call profile after Stop.
                try await systemAudioCapture.start(
                    onPCM: { [weak speakerClient] pcm in speakerClient?.sendAudio(pcm) },
                    onMicrophonePCM: { [weak microphoneClient] pcm in
                        microphoneClient?.sendAudio(pcm)
                    }
                )
                unifiedCapture = true
            } else {
                try microphoneCapture.start { [weak microphoneClient] pcm in
                    microphoneClient?.sendAudio(pcm)
                }
                try await systemAudioCapture.start { [weak speakerClient] pcm in
                    speakerClient?.sendAudio(pcm)
                }
                unifiedCapture = false
            }
            return writer.fileURL
        } catch {
            microphoneCapture.cancel()
            await systemAudioCapture.cancel()
            microphoneClient.cancel()
            speakerClient.cancel()
            writer.discard()
            self.writer = nil
            transcriptURL = nil
            disconnectClients()
            throw error
        }
    }

    func stopAndSave() async throws -> URL {
        guard let writer else { throw ConversationTranscriptionError.stoppedBeforeReady }
        guard !stopping else {
            return try await withCheckedThrowingContinuation { continuation in
                stopContinuations.append(continuation)
            }
        }
        stopping = true
        // Keep both sources alive briefly after the shortcut. ScreenCaptureKit
        // delivers system audio in buffered sample blocks, and immediately
        // stopping it clipped the last spoken word in real conversation files.
        try? await Task.sleep(for: .milliseconds(Self.stopTailCaptureMilliseconds))
        if unifiedCapture {
            await systemAudioCapture.stop()
        } else {
            microphoneCapture.stop()
            await systemAudioCapture.stop()
        }
        microphoneClient.finalize()
        speakerClient.finalize()

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuations.append(continuation)
            finalizationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.completeStop(writer: writer)
            }
        }
    }

    func cancel() async {
        connectionTimeoutTask?.cancel()
        finalizationTimeoutTask?.cancel()
        connectionContinuation?.resume(throwing: CancellationError())
        connectionContinuation = nil
        let pendingStops = stopContinuations
        stopContinuations.removeAll()
        pendingStops.forEach { $0.resume(throwing: CancellationError()) }
        cancelPendingMicrophoneSegments()
        microphoneCapture.cancel()
        await systemAudioCapture.cancel()
        microphoneClient.cancel()
        speakerClient.cancel()
        writer?.discard()
        writer = nil
        transcriptURL = nil
        disconnectClients()
    }

    func closeForApplicationTermination() {
        microphoneCapture.cancel()
        do {
            try flushAllPendingMicrophoneSegments()
            try writer?.finish(ordered: transcriptEntries)
        } catch {
            writer?.closeWithoutFooter()
        }
        disconnectClients()
    }

    private func configureCallbacks() {
        microphoneClient.onConnectionChange = { [weak self] connected in
            self?.setConnection(connected, for: .you)
        }
        speakerClient.onConnectionChange = { [weak self] connected in
            self?.setConnection(connected, for: .speaker)
        }
        microphoneClient.onPartial = { [weak self] text in self?.onPreview?(.you, text) }
        speakerClient.onPartial = { [weak self] text in self?.onPreview?(.speaker, text) }
        microphoneClient.onSegment = { [weak self] segment in self?.append(.you, segment: segment) }
        speakerClient.onSegment = { [weak self] segment in self?.append(.speaker, segment: segment) }
        microphoneClient.onFinal = { [weak self] text in self?.receivedFinal(.you, text: text) }
        speakerClient.onFinal = { [weak self] text in self?.receivedFinal(.speaker, text: text) }
        microphoneClient.onError = { [weak self] error in self?.handleError(error) }
        speakerClient.onError = { [weak self] error in self?.handleError(error) }
    }

    private func waitForConnections() async throws {
        if microphoneConnected && speakerConnected { return }
        try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
            connectionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, let pending = self.connectionContinuation else { return }
                self.connectionContinuation = nil
                pending.resume(throwing: ConversationTranscriptionError.connectionTimedOut)
            }
        }
    }

    private func setConnection(_ connected: Bool, for speaker: ConversationSpeaker) {
        if speaker == .you { microphoneConnected = connected }
        if speaker == .speaker { speakerConnected = connected }
        if microphoneConnected && speakerConnected, let pending = connectionContinuation {
            connectionTimeoutTask?.cancel()
            connectionContinuation = nil
            pending.resume()
        }
    }

    private func append(_ speaker: ConversationSpeaker, segment: RealtimeTranscriptSegment) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recognizedSegments[speaker, default: []].append(text)
        let date = writer?.startedAt.addingTimeInterval(segment.startTime) ?? Date()

        switch speaker {
        case .speaker:
            receiveSpeakerSegment(
                text,
                at: date,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        case .you:
            receiveMicrophoneSegment(
                text,
                at: date,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }
    }

    private func receiveSpeakerSegment(
        _ text: String,
        at date: Date,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        recentSpeakerSegments.removeAll { date.timeIntervalSince($0.date) > 6 }
        recentSpeakerSegments.append(TimedSpeakerSegment(text: text, date: date))

        let pendingIDs = pendingMicrophoneSegments.keys.sorted {
            (pendingMicrophoneSegments[$0]?.date ?? .distantFuture)
                < (pendingMicrophoneSegments[$1]?.date ?? .distantFuture)
        }
        for id in pendingIDs {
            guard var pending = pendingMicrophoneSegments[id],
                  abs(date.timeIntervalSince(pending.date)) <= 4 else { continue }
            let filtered = ConversationEchoFilter.removingEcho(
                from: pending.text,
                matching: text
            )
            guard let filtered else {
                suppressedMicrophoneEchoSegments += 1
                pending.task.cancel()
                pendingMicrophoneSegments.removeValue(forKey: id)
                continue
            }
            let echoWasRemoved = normalized(filtered) != normalized(pending.text)
            pending.text = filtered
            pendingMicrophoneSegments[id] = pending
            if echoWasRemoved || pending.date <= date {
                flushPendingMicrophoneSegment(id: id)
            }
        }

        do {
            try record(
                speaker: .speaker,
                text: text,
                startTime: startTime,
                endTime: endTime
            )
        } catch {
            handleError(error)
        }
    }

    private func receiveMicrophoneSegment(
        _ text: String,
        at date: Date,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        recentSpeakerSegments.removeAll { date.timeIntervalSince($0.date) > 6 }
        var filtered: String? = text
        var echoWasRemoved = false
        for speaker in recentSpeakerSegments where abs(date.timeIntervalSince(speaker.date)) <= 4 {
            guard let candidate = filtered else { break }
            let next = ConversationEchoFilter.removingEcho(from: candidate, matching: speaker.text)
            if normalized(next ?? "") != normalized(candidate) { echoWasRemoved = true }
            filtered = next
        }
        if echoWasRemoved { suppressedMicrophoneEchoSegments += 1 }
        guard let filtered, !filtered.isEmpty else { return }

        let id = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            self?.flushPendingMicrophoneSegment(id: id)
        }
        pendingMicrophoneSegments[id] = PendingMicrophoneSegment(
            text: filtered,
            date: date,
            startTime: startTime,
            endTime: endTime,
            task: task
        )
        if echoWasRemoved { flushPendingMicrophoneSegment(id: id) }
    }

    private func flushPendingMicrophoneSegment(id: UUID) {
        guard let pending = pendingMicrophoneSegments.removeValue(forKey: id) else { return }
        pending.task.cancel()
        do {
            try record(
                speaker: .you,
                text: pending.text,
                startTime: pending.startTime,
                endTime: pending.endTime
            )
        } catch {
            handleError(error)
        }
    }

    private func flushAllPendingMicrophoneSegments() throws {
        let pending = pendingMicrophoneSegments.values.sorted { $0.date < $1.date }
        pendingMicrophoneSegments.removeAll()
        for segment in pending {
            segment.task.cancel()
            try record(
                speaker: .you,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }
    }

    private func cancelPendingMicrophoneSegments() {
        pendingMicrophoneSegments.values.forEach { $0.task.cancel() }
        pendingMicrophoneSegments.removeAll()
    }

    private func receivedFinal(_ speaker: ConversationSpeaker, text: String) {
        appendFinalRemainderIfNeeded(speaker, finalText: text)
        if speaker == .you { microphoneFinal = text }
        if speaker == .speaker { speakerFinal = text }
        if stopping, microphoneFinal != nil, speakerFinal != nil, let writer {
            completeStop(writer: writer)
        }
    }

    private func appendFinalRemainderIfNeeded(_ speaker: ConversationSpeaker, finalText: String) {
        let final = normalized(finalText)
        guard !final.isEmpty else { return }
        let recognized = normalized(recognizedSegments[speaker, default: []].joined(separator: " "))
        guard final != recognized else { return }
        if !recognized.isEmpty, final.hasPrefix(recognized) {
            let index = final.index(final.startIndex, offsetBy: recognized.count)
            appendFallback(
                speaker,
                text: String(final[index...]).trimmingCharacters(in: .whitespaces)
            )
        } else if recognized.isEmpty {
            appendFallback(speaker, text: finalText)
        }
    }

    private func appendFallback(_ speaker: ConversationSpeaker, text: String) {
        let elapsed = max(0, Date().timeIntervalSince(writer?.startedAt ?? Date()))
        append(
            speaker,
            segment: RealtimeTranscriptSegment(
                text: text,
                startTime: elapsed,
                endTime: elapsed
            )
        )
    }

    private func record(
        speaker: ConversationSpeaker,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) throws {
        let clampedStartTime = max(0, startTime)
        let entry = ConversationTranscriptEntry(
            speaker: speaker,
            text: text,
            startTime: clampedStartTime,
            endTime: max(clampedStartTime, endTime),
            sequence: nextEntrySequence
        )
        try writer?.append(entry)
        transcriptEntries.append(entry)
        nextEntrySequence += 1
    }

    private func completeStop(writer: ConversationTranscriptWriter) {
        guard !stopContinuations.isEmpty else { return }
        finalizationTimeoutTask?.cancel()
        let continuations = stopContinuations
        stopContinuations.removeAll()
        do {
            try flushAllPendingMicrophoneSegments()
            try writer.finish(ordered: transcriptEntries)
            logger.info(
                "CONVERSATION_CHANNELS youRecognized=\(self.recognizedSegments[.you, default: []].count, privacy: .public) speakerRecognized=\(self.recognizedSegments[.speaker, default: []].count, privacy: .public) microphoneEchoSuppressed=\(self.suppressedMicrophoneEchoSegments, privacy: .public)"
            )
            disconnectClients()
            continuations.forEach { $0.resume(returning: writer.fileURL) }
        } catch {
            disconnectClients()
            continuations.forEach { $0.resume(throwing: error) }
        }
    }

    private func handleError(_ error: Error) {
        if let pending = connectionContinuation {
            connectionTimeoutTask?.cancel()
            connectionContinuation = nil
            pending.resume(throwing: error)
            return
        }
        guard !stopping else { return }
        onError?(error)
    }

    private func disconnectClients() {
        microphoneClient.disconnect()
        speakerClient.disconnect()
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
