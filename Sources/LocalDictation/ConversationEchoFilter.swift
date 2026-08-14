import Foundation

/// Removes a time-correlated system-audio phrase from a microphone transcript.
/// Matching is intentionally conservative: short/common phrases are retained,
/// while longer phrases tolerate substitutions caused by a noisy microphone.
enum ConversationEchoFilter {
    private static let minimumEchoWords = 6

    private struct Token {
        let normalized: String
        let range: Range<String.Index>
    }

    private struct Match {
        let score: Double
        let microphoneStart: Int
        let microphoneLength: Int

        // Prefer a longer, strong match over a short accidental phrase, while
        // heavily penalizing a longer range padded with unrelated user words.
        var rank: Double {
            Double(microphoneLength) * max(0, score - 0.5)
        }
    }

    static func removingEcho(from microphone: String, matching speaker: String) -> String? {
        let microphoneTokens = tokens(in: microphone)
        let speakerTokens = tokens(in: speaker).map(\.normalized)
        guard microphoneTokens.count >= minimumEchoWords,
              speakerTokens.count >= minimumEchoWords else {
            return cleaned(microphone)
        }

        let substitutionCosts = microphoneTokens.map { microphoneToken in
            speakerTokens.map { speakerToken in
                substitutionCost(microphoneToken.normalized, speakerToken)
            }
        }
        var best: Match?
        for microphoneRange in edgeRanges(tokenCount: microphoneTokens.count) {
            let microphoneLength = microphoneRange.count
            let score = substringSimilarity(
                microphoneRange: microphoneRange,
                speakerCount: speakerTokens.count,
                substitutionCosts: substitutionCosts
            )
            guard score >= acceptanceThreshold(wordCount: microphoneLength) else {
                continue
            }
            let match = Match(
                score: score,
                microphoneStart: microphoneRange.lowerBound,
                microphoneLength: microphoneLength
            )
            if best == nil
                || match.rank > best!.rank
                || (match.rank == best!.rank && match.score > best!.score) {
                best = match
            }
        }

        guard let best else { return cleaned(microphone) }
        let first = best.microphoneStart
        let last = best.microphoneStart + best.microphoneLength - 1
        let removalRange: Range<String.Index>
        if first == 0, last == microphoneTokens.count - 1 {
            return nil
        } else if first == 0 {
            removalRange = microphone.startIndex..<microphoneTokens[last + 1].range.lowerBound
        } else if last == microphoneTokens.count - 1 {
            removalRange = microphoneTokens[first].range.lowerBound..<microphone.endIndex
        } else {
            removalRange = microphoneTokens[first].range.lowerBound..<microphoneTokens[last + 1].range.lowerBound
        }

        var result = microphone
        result.removeSubrange(removalRange)
        let remainder = cleaned(result)
        return remainder.isEmpty ? nil : remainder
    }

    /// Speaker leakage normally occupies the entire microphone segment or one
    /// edge when the local user talks immediately before/after it. Limiting the
    /// search to those ranges prevents cubic work on long Zoom turns and avoids
    /// deleting an incidental phrase from the middle of genuine user speech.
    private static func edgeRanges(tokenCount: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for length in minimumEchoWords...tokenCount {
            ranges.append(0..<length)
            let suffix = (tokenCount - length)..<tokenCount
            if suffix.lowerBound != 0 { ranges.append(suffix) }
        }
        return ranges
    }

    private static func acceptanceThreshold(wordCount: Int) -> Double {
        if wordCount <= 7 { return 0.90 }
        if wordCount <= 11 { return 0.78 }
        return 0.62
    }

    private static func tokens(in text: String) -> [Token] {
        let pattern = #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = text[range]
                .lowercased()
                .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            return Token(normalized: value, range: range)
        }
    }

    /// Semi-global word alignment: the complete microphone candidate must
    /// match, while unrelated words before or after it in a longer clean
    /// Speaker segment are free. This handles different ASR endpointing without
    /// an expensive all-window search.
    private static func substringSimilarity(
        microphoneRange: Range<Int>,
        speakerCount: Int,
        substitutionCosts: [[Double]]
    ) -> Double {
        guard !microphoneRange.isEmpty, speakerCount > 0 else { return 0 }
        var previous = Array(repeating: 0.0, count: speakerCount + 1)
        for (offset, microphoneIndex) in microphoneRange.enumerated() {
            var current = Array(repeating: 0.0, count: speakerCount + 1)
            current[0] = Double(offset + 1)
            for speakerIndex in 0..<speakerCount {
                current[speakerIndex + 1] = min(
                    current[speakerIndex] + 1,
                    previous[speakerIndex + 1] + 1,
                    previous[speakerIndex] + substitutionCosts[microphoneIndex][speakerIndex]
                )
            }
            previous = current
        }
        let distance = previous.min() ?? Double(microphoneRange.count)
        return max(0, 1 - distance / Double(microphoneRange.count))
    }

    private static func substitutionCost(_ left: String, _ right: String) -> Double {
        if left == right { return 0 }
        if min(left.count, right.count) >= 4,
           left.hasPrefix(right) || right.hasPrefix(left) {
            return 0.25
        }
        let characterDistance = levenshtein(Array(left), Array(right))
        let ratio = Double(characterDistance) / Double(max(left.count, right.count))
        return ratio <= 0.25 ? 0.35 : 1
    }

    private static func levenshtein<T: Equatable>(_ left: [T], _ right: [T]) -> Int {
        var previous = Array(0...right.count)
        for (leftIndex, leftValue) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightValue) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftValue == rightValue ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
