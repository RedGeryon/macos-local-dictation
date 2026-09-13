import Foundation

/// One finished quick dictation. Only the current session remembers these;
/// nothing is written to disk.
struct DictationHistoryEntry: Equatable, Identifiable, Sendable {
    let id: UUID
    let rawTranscript: String
    let text: String
    let date: Date

    /// A single-line preview for menus.
    var menuTitle: String {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let limit = 48
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The last few dictations, newest first.
struct DictationHistory: Equatable, Sendable {
    static let capacity = 5

    private(set) var entries: [DictationHistoryEntry] = []

    var isEmpty: Bool { entries.isEmpty }
    var newest: DictationHistoryEntry? { entries.first }

    mutating func record(rawTranscript: String, text: String, date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Re-dictating the same sentence should not fill the list with copies.
        entries.removeAll { $0.text == trimmed }
        entries.insert(DictationHistoryEntry(id: UUID(), rawTranscript: rawTranscript, text: trimmed, date: date), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    func entry(id: UUID) -> DictationHistoryEntry? {
        entries.first { $0.id == id }
    }
}
