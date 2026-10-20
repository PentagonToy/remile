import Foundation

struct AssistantLocation: Identifiable, Hashable, Sendable, Codable {
    let path: String
    let unit: Int
    let label: String
    var id: String { path + "#" + String(unit) }
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}

struct AssistantPassage: Identifiable, Sendable {
    let location: AssistantLocation
    let text: String
    var id: String { location.id }
}

/// A click has its own identity so selecting the same citation can refocus a scrolled view.
struct AssistantCitation: Identifiable, Sendable {
    let id = UUID()
    let location: AssistantLocation
    let text: String

    /// Match the supplied excerpt, never an invented quotation from a generated answer.
    func ranges(in text: String) -> [NSRange] {
        struct Token { let word: String; let range: NSRange }
        func tokens(_ value: String) -> [Token] {
            let source = value as NSString
            let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}\\p{M}]+|[%\\p{Sm}/-]")
            return regex.matches(in: value, range: NSRange(location: 0, length: source.length)).map {
                Token(word: source.substring(with: $0.range).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")), range: $0.range)
            }
        }
        let source = tokens(text), quote = tokens(self.text)
        guard !quote.isEmpty, quote.count <= source.count else { return [] }
        // Excerpts may start/end inside a word when clipped by the index or evidence budget.
        for (leading, trailing) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            guard quote.count > leading + trailing else { continue }
            let phrase = Array(quote.dropFirst(leading).dropLast(trailing))
            guard leading + trailing == 0 || phrase.count >= 4 else { continue }
            var result: [NSRange] = []
            for start in 0...(source.count - phrase.count) {
                if phrase.indices.allSatisfy({ offset in
                    let word = source[start + offset].word, expected = phrase[offset].word
                    return word == expected || (offset == phrase.count - 1 && expected.count >= 4 && word.hasPrefix(expected))
                }) {
                    let first = source[start].range, last = source[start + phrase.count - 1].range
                    result.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
                    if result.count == 8 { break }
                }
            }
            if !result.isEmpty { return result }
        }
        return []
    }
}


enum AssistantRetrieval {
    static func rank(_ passages: [AssistantPassage], question: String) -> [AssistantPassage] {
        let ignored: Set<String> = ["what", "which", "where", "when", "this", "that", "these", "those", "does", "with", "from", "about", "please", "explain", "document", "according", "their", "have", "would", "could"]
        let terms = Set(question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !ignored.contains($0) })
        func score(_ passage: AssistantPassage) -> Int { let text = passage.text.lowercased(); return terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) } }
        let scored: [(Int, AssistantPassage, Int)] = passages.enumerated().map { ($0.offset, $0.element, score($0.element)) }
        let ordered = scored.sorted { first, second in first.2 == second.2 ? first.0 < second.0 : first.2 > second.2 }
        return ordered.map { $0.1 }
    }
}
