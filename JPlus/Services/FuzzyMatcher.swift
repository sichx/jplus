import Foundation

/// Typo-tolerant word matching used by the Google-style search.
nonisolated enum FuzzyMatcher {
    static let stopWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "for", "and", "or", "is", "are", "be",
        "with", "by", "at", "from", "as", "it", "this", "that", "not", "no",
    ]

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func words(_ text: String) -> [String] {
        normalize(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Query words without stop words (unless that would leave nothing).
    static func queryTokens(_ text: String) -> [String] {
        let all = words(text)
        let meaningful = all.filter { !stopWords.contains($0) }
        return meaningful.isEmpty ? all : meaningful
    }

    /// How well `word` matches query token `q`, from 0 (no match) to 1 (exact).
    static func quality(_ q: String, _ word: String) -> Double {
        if word == q { return 1 }
        let qCount = q.count
        if qCount >= 2, word.hasPrefix(q) { return 0.9 }        // still typing: "leaderb"
        guard qCount >= 4 else { return 0 }                    // short words must be exact or a prefix
        if word.count >= 4, q.hasPrefix(word) { return 0.55 }  // extra letters: "boards" vs "board"
        let allowed = qCount <= 5 ? 1 : 2
        if abs(word.count - qCount) <= allowed, let distance = editDistance(q, word, limit: allowed) {
            return 0.8 - 0.1 * Double(distance - 1)           // typo: "leadrbord"
        }
        if word.count > qCount, editDistance(q, String(word.prefix(qCount)), limit: 1) != nil {
            return 0.65                                        // typo while typing: "leadrb"
        }
        if qCount >= 5, word.contains(q) { return 0.5 }
        return 0
    }

    struct TitleMatch: Sendable {
        /// Average match quality over the query words, 0...1.
        let score: Double
        /// Title words (normalized) that matched, for highlighting.
        let matchedWords: Set<String>
        /// Query word -> the title word it was corrected to, for "Did you mean".
        let corrections: [String: String]
        let matchedCount: Int
    }

    /// Matches query tokens against a title's words. Short queries need every
    /// word to match; longer ones may miss one.
    static func match(_ queryTokens: [String], titleWords: [String]) -> TitleMatch? {
        guard !queryTokens.isEmpty, !titleWords.isEmpty else { return nil }
        var total = 0.0
        var matched = 0
        var matchedWords = Set<String>()
        var corrections: [String: String] = [:]

        for q in queryTokens {
            var best = 0.0
            var bestWord: String?
            for word in titleWords {
                let value = quality(q, word)
                if value > best {
                    best = value
                    bestWord = word
                    if value == 1 { break }
                }
            }
            if best > 0, let bestWord {
                total += best
                matched += 1
                matchedWords.insert(bestWord)
                if best < 0.9 { corrections[q] = bestWord }
            }
        }

        let required = queryTokens.count <= 2 ? queryTokens.count : queryTokens.count - 1
        guard matched >= required else { return nil }
        return TitleMatch(
            score: total / Double(queryTokens.count),
            matchedWords: matchedWords,
            corrections: corrections,
            matchedCount: matched
        )
    }

    /// Optimal-string-alignment distance, or nil once it exceeds `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int? {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return nil }
        if a.isEmpty { return b.count <= limit ? b.count : nil }
        if b.isEmpty { return a.count <= limit ? a.count : nil }

        var previousPrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previousPrevious[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return nil }
            (previousPrevious, previous, current) = (previous, current, previousPrevious)
        }
        let distance = previous[b.count]
        return distance <= limit ? distance : nil
    }
}
