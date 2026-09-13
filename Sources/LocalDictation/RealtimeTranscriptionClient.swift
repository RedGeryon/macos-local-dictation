import Foundation
import OSLog

enum RealtimeTranscriptionError: LocalizedError {
    case notConnected
    case server(String)
    case invalidEvent

    var errorDescription: String? {
        switch self {
        case .notConnected: return "The live transcription connection is not ready."
        case .server(let message): return "The speech engine reported: \(message)"
        case .invalidEvent: return "The speech engine sent an unreadable response."
        }
    }
}

/// A pause-bounded recognition result on the stream's audio clock. Word
/// timestamps let two independent recognizers be merged chronologically even
/// when their results arrive at different wall-clock times.
struct RealtimeTranscriptSegment: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// One long-lived WebSocket maps to one stateful NeMo recognition stream. All
/// outgoing audio and control messages share a serial queue so commit can never
/// overtake the final PCM frame.
final class RealtimeTranscriptionClient: @unchecked Sendable {
    typealias TextHandler = @MainActor (String) -> Void
    typealias SegmentHandler = @MainActor (RealtimeTranscriptSegment) -> Void
    typealias ErrorHandler = @MainActor (Error) -> Void
    typealias ConnectionHandler = @MainActor (Bool) -> Void
    typealias ConnectionEventHandler = @MainActor (Bool, UUID?) -> Void
    typealias ErrorEventHandler = @MainActor (Error, UUID?) -> Void
    typealias ClearedHandler = @MainActor () -> Void

    private let logger = Logger(subsystem: "org.localdictation.app", category: "RealtimeASR")
    private let session: URLSession
    private let queue = DispatchQueue(label: "org.localdictation.realtime")
    private var socket: URLSessionWebSocketTask?
    private var outgoingMessages: [URLSessionWebSocketTask.Message] = []
    private var sendInFlight = false
    private var completedSegments: [String] = []
    private var partial = ""
    private var lastCompletedEndTime: TimeInterval = 0
    private var acceptingResults = false
    private var connected = false
    private var connectionID: UUID?

    var onPartial: TextHandler?
    var onSegment: SegmentHandler?
    var onFinal: TextHandler?
    var onError: ErrorHandler?
    var onConnectionChange: ConnectionHandler?
    /// Session-aware events let an owner ignore callbacks from a socket that
    /// was deliberately replaced during an engine/model switch.
    var onConnectionEvent: ConnectionEventHandler?
    var onErrorEvent: ErrorEventHandler?
    var onCleared: ClearedHandler?

    init(session: URLSession = .shared) {
        self.session = session
    }

    @discardableResult
    func connect(
        to url: URL,
        automaticPunctuation: Bool,
        languageCode: String = RecognitionLanguage.englishUS.rawValue,
        wordTimestamps: Bool = false,
        endpointingMilliseconds: Int? = nil
    ) -> UUID {
        let newConnectionID = UUID()
        queue.async { [weak self] in
            guard let self else { return }
            self.disconnectLocked(notify: false)
            self.connectionID = newConnectionID
            let socket = self.session.webSocketTask(with: url)
            self.socket = socket
            socket.resume()
            self.receiveNext(on: socket)
            self.sendJSONLocked(Self.sessionUpdateMessage(
                automaticPunctuation: automaticPunctuation,
                languageCode: languageCode,
                wordTimestamps: wordTimestamps,
                endpointingMilliseconds: endpointingMilliseconds
            ))
        }
        return newConnectionID
    }

    static func sessionUpdateMessage(
        automaticPunctuation: Bool,
        languageCode: String,
        wordTimestamps: Bool,
        endpointingMilliseconds: Int?
    ) -> [String: Any] {
        var configuration: [String: Any] = [
            "sample_rate": 16_000,
            "language": languageCode,
            "automatic_punctuation": automaticPunctuation,
            "word_timestamps": wordTimestamps,
            "speaker_diarization": false
        ]
        if let endpointingMilliseconds {
            configuration["endpointing_ms"] = endpointingMilliseconds
        }
        return [
            "type": "session.update",
            "session": configuration
        ]
    }

    func disconnect() {
        queue.async { [weak self] in self?.disconnectLocked(notify: true) }
    }

    func updateLanguage(_ languageCode: String, automaticPunctuation: Bool) {
        queue.async { [weak self] in
            guard let self, self.connected else {
                self?.notifyError(RealtimeTranscriptionError.notConnected)
                return
            }
            self.sendJSONLocked(Self.sessionUpdateMessage(
                automaticPunctuation: automaticPunctuation,
                languageCode: languageCode,
                wordTimestamps: false,
                endpointingMilliseconds: nil
            ))
        }
    }

    func beginUtterance() {
        queue.async { [weak self] in
            guard let self else { return }
            self.completedSegments.removeAll(keepingCapacity: true)
            self.partial = ""
            self.lastCompletedEndTime = 0
            self.acceptingResults = true
        }
    }

    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.acceptingResults else { return }
            guard let socket = self.socket, self.connected else {
                self.notifyError(RealtimeTranscriptionError.notConnected)
                return
            }
            self.enqueueMessageLocked(.data(pcm16), on: socket)
        }
    }

    func finalize() {
        queue.async { [weak self] in
            guard let self, self.acceptingResults else { return }
            self.sendJSONLocked(["type": "input_audio_buffer.commit"])
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.acceptingResults = false
            self.completedSegments.removeAll(keepingCapacity: true)
            self.partial = ""
            self.sendJSONLocked(["type": "input_audio_buffer.clear"])
        }
    }

    private func receiveNext(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            self.queue.async {
                guard self.socket === socket else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveNext(on: socket)
                case .failure(let error):
                    self.connected = false
                    self.notifyConnection(false, connectionID: self.connectionID)
                    if (error as NSError).code != NSURLErrorCancelled {
                        self.notifyError(error)
                    }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            notifyError(RealtimeTranscriptionError.invalidEvent)
            return
        }

        switch type {
        case "session.created":
            connected = true
            notifyConnection(true, connectionID: connectionID)
        case "session.updated":
            logger.info("REALTIME_SESSION_READY")
        case "conversation.item.input_audio_transcription.delta":
            guard acceptingResults else { return }
            partial += event["delta"] as? String ?? ""
            notifyPartial(renderedTranscript())
        case "conversation.item.input_audio_transcription.completed":
            guard acceptingResults else { return }
            let transcript = (event["transcript"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                completedSegments.append(transcript)
                let segment = Self.transcriptSegment(
                    from: event,
                    transcript: transcript,
                    fallbackStartTime: lastCompletedEndTime
                )
                lastCompletedEndTime = max(lastCompletedEndTime, segment.endTime)
                notifySegment(segment)
            }
            partial = ""
            notifyPartial(renderedTranscript())
        case "input_audio_buffer.committed":
            guard acceptingResults else { return }
            acceptingResults = false
            let final = completedSegments.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completedSegments.removeAll(keepingCapacity: true)
            partial = ""
            notifyFinal(final)
        case "input_audio_buffer.cleared":
            notifyCleared()
        case "error":
            let details = event["error"] as? [String: Any]
            notifyError(RealtimeTranscriptionError.server(details?["message"] as? String ?? "Unknown error"))
        default:
            break
        }
    }

    private func renderedTranscript() -> String {
        let committed = completedSegments.joined(separator: " ")
        return [committed, partial]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func sendJSONLocked(_ object: [String: Any]) {
        guard let socket else {
            notifyError(RealtimeTranscriptionError.notConnected)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            notifyError(RealtimeTranscriptionError.invalidEvent)
            return
        }
        enqueueMessageLocked(.string(text), on: socket)
    }

    private func enqueueMessageLocked(
        _ message: URLSessionWebSocketTask.Message,
        on socket: URLSessionWebSocketTask
    ) {
        guard self.socket === socket else { return }
        outgoingMessages.append(message)
        sendNextMessageLocked()
    }

    private func sendNextMessageLocked() {
        guard !sendInFlight,
              let socket,
              !outgoingMessages.isEmpty else { return }
        let message = outgoingMessages.removeFirst()
        sendInFlight = true
        socket.send(message) { [weak self, weak socket] error in
            guard let self, let socket else { return }
            self.queue.async {
                guard self.socket === socket else { return }
                self.sendInFlight = false
                if let error {
                    self.outgoingMessages.removeAll(keepingCapacity: true)
                    self.notifyError(error)
                    return
                }
                self.sendNextMessageLocked()
            }
        }
    }

    private func disconnectLocked(notify: Bool) {
        let disconnectedID = connectionID
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        outgoingMessages.removeAll(keepingCapacity: false)
        sendInFlight = false
        connected = false
        connectionID = nil
        acceptingResults = false
        completedSegments.removeAll()
        partial = ""
        lastCompletedEndTime = 0
        if notify { notifyConnection(false, connectionID: disconnectedID) }
    }

    private func notifyPartial(_ text: String) {
        Task { @MainActor [weak self] in self?.onPartial?(text) }
    }

    private func notifyFinal(_ text: String) {
        Task { @MainActor [weak self] in self?.onFinal?(text) }
    }

    private func notifySegment(_ segment: RealtimeTranscriptSegment) {
        Task { @MainActor [weak self] in self?.onSegment?(segment) }
    }

    private func notifyError(_ error: Error) {
        let eventConnectionID = connectionID
        Task { @MainActor [weak self] in
            self?.onError?(error)
            self?.onErrorEvent?(error, eventConnectionID)
        }
    }

    private func notifyConnection(_ value: Bool, connectionID: UUID?) {
        Task { @MainActor [weak self] in
            self?.onConnectionChange?(value)
            self?.onConnectionEvent?(value, connectionID)
        }
    }

    private func notifyCleared() {
        Task { @MainActor [weak self] in self?.onCleared?() }
    }

    static func transcriptSegment(
        from event: [String: Any],
        transcript: String,
        fallbackStartTime: TimeInterval
    ) -> RealtimeTranscriptSegment {
        let words = event["words"] as? [[String: Any]] ?? []
        let starts = words.compactMap { $0["start"] as? Double }
        let ends = words.compactMap { $0["end"] as? Double }
        let start = starts.min() ?? fallbackStartTime
        let processed = event["audio_processed"] as? Double
        let end = max(start, ends.max() ?? processed ?? start)
        return RealtimeTranscriptSegment(text: transcript, startTime: start, endTime: end)
    }
}
