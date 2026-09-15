import Foundation

/// Conversation and media transcripts share one folder per local calendar day.
enum TranscriptStorage {
    static func directory(fileManager: FileManager = .default) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("Local Dictation Transcripts", isDirectory: true)
    }

    static func dailyDirectory(at date: Date, fileManager: FileManager = .default) throws -> URL {
        let directory = dailyDirectory(in: try directory(fileManager: fileManager), at: date)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func dailyDirectory(in root: URL, at date: Date, timeZone: TimeZone = .current) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }
}
