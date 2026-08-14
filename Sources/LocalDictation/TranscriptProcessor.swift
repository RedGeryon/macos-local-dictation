import Foundation

struct InsertionContext: Equatable, Sendable {
    var textBeforeCursor: String = ""
    var textAfterCursor: String = ""
}

struct ProcessedTranscript: Equatable, Sendable {
    let text: String
    let shouldPressReturn: Bool
}

enum TranscriptProcessor {
    static func process(
        _ rawTranscript: String,
        context: InsertionContext = InsertionContext(),
        removeFillers: Bool = true
    ) -> ProcessedTranscript {
        var text = rawTranscript.precomposedStringWithCanonicalMapping
        text = normalizeWhitespace(text)

        let command = extractReturnCommand(from: text)
        text = command.text
        text = expandParagraphCommands(in: text)
        if removeFillers {
            text = removeConservativeDisfluencies(from: text)
        }
        text = normalizePunctuationSpacing(text)
        text = formatBoundary(text, context: context)

        return ProcessedTranscript(text: text, shouldPressReturn: command.shouldPressReturn)
    }

    static func normalizeWhitespace(_ input: String) -> String {
        input
            .replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractReturnCommand(from input: String) -> (text: String, shouldPressReturn: Bool) {
        let pattern = "(?i)(?:[,;:]?\\s*)press enter[.!?]?$"
        guard let range = input.range(of: pattern, options: .regularExpression) else {
            return (input, false)
        }
        var text = input
        text.removeSubrange(range)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    private static func expandParagraphCommands(in input: String) -> String {
        input
            .replacingOccurrences(
                of: "(?i)\\s*new paragraph[,.]?\\s*",
                with: "\n\n",
                options: .regularExpression
            )
    }

    private static func removeConservativeDisfluencies(from input: String) -> String {
        var result = input.replacingOccurrences(
            of: "(?i)(^|[\\s])(?:um+|uh+)(?=[\\s,.!?]|$)[,]?",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?i)\\b([[:alnum:]']+)\\s+\\1\\b",
            with: "$1",
            options: .regularExpression
        )
        return normalizeWhitespace(result)
    }

    private static func normalizePunctuationSpacing(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "([,.;:!?])([^\\s\\n])", with: "$1 $2", options: .regularExpression)
    }

    private static func formatBoundary(_ input: String, context: InsertionContext) -> String {
        guard !input.isEmpty else { return input }
        var output = input
        let previous = context.textBeforeCursor.last
        let next = context.textAfterCursor.first

        if let previous,
           !previous.isWhitespace,
           !previous.isNewline,
           !isOpeningPunctuation(previous),
           let first = output.first,
           !first.isWhitespace,
           !isClosingPunctuation(first) {
            output.insert(" ", at: output.startIndex)
        }

        if let next,
           !next.isWhitespace,
           !next.isNewline,
           !isClosingPunctuation(next),
           let last = output.last,
           !last.isWhitespace,
           !last.isNewline,
           !isOpeningPunctuation(last) {
            output.append(" ")
        }

        return output
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        "([{\u{201C}\u{2018}".contains(character)
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        ",.;:!?)]}\u{201D}\u{2019}".contains(character)
    }
}
