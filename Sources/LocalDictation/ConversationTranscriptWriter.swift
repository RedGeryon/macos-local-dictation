import Foundation

enum ConversationSpeaker: String, CaseIterable, Sendable {
    case you = "You"
    case speaker = "Speaker"
}

struct ConversationTranscriptEntry: Equatable, Sendable {
    let speaker: ConversationSpeaker
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let sequence: Int

    static func chronological(_ entries: [Self]) -> [Self] {
        entries.sorted {
            if $0.startTime != $1.startTime {
                return $0.startTime < $1.startTime
            }
            if $0.endTime != $1.endTime {
                return $0.endTime < $1.endTime
            }
            return $0.sequence < $1.sequence
        }
    }
}

enum ConversationTranscriptFormatter {
    static func header(startedAt: Date, microphoneName: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let microphone = microphoneName?.isEmpty == false ? microphoneName! : "System default"
        return """
        Conversation Transcript
        Started: \(formatter.string(from: startedAt))
        Microphone: \(microphone)
        Speaker audio: Mac system audio

        """
    }

    static func line(elapsed: TimeInterval, speaker: ConversationSpeaker, text: String) -> String {
        let totalSeconds = max(0, Int(elapsed.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let timestamp = hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(timestamp)] \(speaker.rawValue): \(cleaned)\n\n"
    }

    static func footer(endedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return "---\nEnded: \(formatter.string(from: endedAt))\n"
    }

    static func document(
        startedAt: Date,
        microphoneName: String?,
        entries: [ConversationTranscriptEntry],
        endedAt: Date
    ) -> String {
        let body = ConversationTranscriptEntry.chronological(entries)
            .map { line(elapsed: $0.startTime, speaker: $0.speaker, text: $0.text) }
            .joined()
        return header(startedAt: startedAt, microphoneName: microphoneName)
            + body
            + footer(endedAt: endedAt)
    }
}

@MainActor
final class ConversationTranscriptWriter {
    let fileURL: URL
    let startedAt: Date

    private var fileHandle: FileHandle?
    private let microphoneName: String?

    static func transcriptsDirectory() throws -> URL {
        try TranscriptStorage.directory()
    }

    init(startedAt: Date = Date(), microphoneName: String? = nil) throws {
        self.startedAt = startedAt
        self.microphoneName = microphoneName
        let fileManager = FileManager.default
        let directory = try TranscriptStorage.dailyDirectory(at: startedAt)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let filenameFormatter = DateFormatter()
        filenameFormatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "Conversation \(filenameFormatter.string(from: startedAt))"
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("txt")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) (\(suffix))")
                .appendingPathExtension("txt")
            suffix += 1
        }
        guard fileManager.createFile(atPath: candidate.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        fileURL = candidate
        let handle = try FileHandle(forWritingTo: candidate)
        fileHandle = handle
        try write(ConversationTranscriptFormatter.header(
            startedAt: startedAt,
            microphoneName: microphoneName
        ))
    }

    func append(speaker: ConversationSpeaker, text: String, at date: Date = Date()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try write(ConversationTranscriptFormatter.line(
            elapsed: date.timeIntervalSince(startedAt),
            speaker: speaker,
            text: text
        ))
    }

    func append(_ entry: ConversationTranscriptEntry) throws {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try write(ConversationTranscriptFormatter.line(
            elapsed: entry.startTime,
            speaker: entry.speaker,
            text: entry.text
        ))
    }

    func finish(at date: Date = Date()) throws {
        guard fileHandle != nil else { return }
        try write(ConversationTranscriptFormatter.footer(endedAt: date))
        try fileHandle?.close()
        fileHandle = nil
    }

    /// Replaces the live append journal with a timestamp-sorted final document.
    /// Until this succeeds, the incrementally synchronized journal remains
    /// readable if the app or Mac exits unexpectedly.
    func finish(ordered entries: [ConversationTranscriptEntry], at date: Date = Date()) throws {
        guard fileHandle != nil else { return }
        try fileHandle?.close()
        fileHandle = nil
        let document = ConversationTranscriptFormatter.document(
            startedAt: startedAt,
            microphoneName: microphoneName,
            entries: entries,
            endedAt: date
        )
        guard let data = document.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    func closeWithoutFooter() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    func discard() {
        closeWithoutFooter()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func write(_ text: String) throws {
        guard let data = text.data(using: .utf8), let fileHandle else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try fileHandle.write(contentsOf: data)
        try fileHandle.synchronize()
    }
}
