import Foundation

/// Unicode word matching shared by excerpts and both preview renderers.
struct SearchText {
    struct Match { let range: NSRange; let group: Int }
    private struct Token { let word: String; let range: NSRange }
    private static func tokens(_ text: String) -> [Token] {
        let source = text as NSString
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}\\p{M}]+")
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            Token(word: source.substring(with: $0.range).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")), range: $0.range)
        }
    }
    static func matches(_ text: String, query: String, limit: Int = 500) -> [Match] {
        guard let groups = try? LibraryIndex.queryTerms(query) else { return [] }
        let words = tokens(text)
        var found: [Match] = []
        for (group, term) in groups.enumerated() {
            let phrase = tokens(term).map(\.word)
            guard !phrase.isEmpty, phrase.count <= words.count else { continue }
            var groupCount = 0
            for start in 0...(words.count - phrase.count) {
                if phrase.indices.allSatisfy({ words[start + $0].word == phrase[$0] }) {
                    let end = words[start + phrase.count - 1].range
                    found.append(Match(range: NSRange(location: words[start].range.location, length: NSMaxRange(end) - words[start].range.location), group: group))
                    groupCount += 1
                    if groupCount >= max(1, limit / groups.count) { break }
                }
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }
    /// A small proximity boost retains BM25 as the baseline; never a probability.
    static func context(_ text: String, query: String) -> (excerpt: String, proximity: Double) {
        let source = text as NSString, matches = matches(text, query: query, limit: 4000)
        let groups = (try? LibraryIndex.queryTerms(query).count) ?? 0
        guard let first = matches.first else { return (String(text.prefix(360)), 0) }
        var best = first.range, bestLength = Int.max, counts: [Int: Int] = [:], left = 0
        for right in matches.indices {
            counts[matches[right].group, default: 0] += 1
            while counts.count == groups, left <= right {
                let end = matches[left...right].map { NSMaxRange($0.range) }.max()!
                let span = NSRange(location: matches[left].range.location, length: end - matches[left].range.location)
                if span.length < bestLength { best = span; bestLength = span.length }
                let group = matches[left].group
                counts[group]! -= 1; if counts[group] == 0 { counts.removeValue(forKey: group) }; left += 1
            }
        }
        let begin = max(0, best.location - 100), end = min(source.length, max(NSMaxRange(best), best.location + 240))
        // Expand composed character boundaries rather than splitting Unicode text.
        let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: begin, length: min(440, end - begin)))
        let excerpt = (range.location > 0 ? "… " : "") + source.substring(with: range).replacingOccurrences(of: "\n", with: " ") + (NSMaxRange(range) < source.length ? " …" : "")
        return (excerpt, groups > 1 && bestLength != Int.max ? 1 / (1 + Double(bestLength) / 80) : 0)
    }
}
