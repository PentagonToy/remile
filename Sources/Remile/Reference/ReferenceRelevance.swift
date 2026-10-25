import Foundation

/// Local retrieval, not an entailment verdict. No model, network access or PDF reads.
enum ReferenceRelevance {
    struct Document: Sendable {
        let title: Set<String>
        let terms: [String: Int]
        let abstract: String
        init(title: String, abstract: String) {
            let title = String(title.prefix(2000))
            self.title = Set(ReferenceRelevance.tokens(title))
            self.abstract = String(abstract.prefix(12_000))
            terms = ReferenceRelevance.tokens(title + " " + self.abstract).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
    }
    enum Intent: String, Sendable {
        case background, foundation, method, comparison, unclear
        var title: String {
            switch self { case .background: "Background"; case .foundation: "Fact or mechanism"; case .method: "Method or tool"; case .comparison: "Comparison"; case .unclear: "Context" }
        }
    }
    struct Assessment: Sendable {
        let label: String
        let basis: String
        let intents: [Intent]
        let matched: [String]
        let excerpt: String
        var note: String {
            if intents.contains(.comparison) { return "Check values, units and conditions in the original." }
            if intents.contains(.foundation) { return "Check the claim and conditions in the original." }
            if intents.contains(.method) { return "Check the original method and version." }
            return "Topic similarity does not verify the claim."
        }
    }
    struct Context: Sendable {
        let terms: [String]
        let intents: [Intent]
        init(_ text: String) {
            let text = ReferenceRelevance.plain(String(text.suffix(1200)))
            terms = Array(Set(ReferenceRelevance.tokens(text))).sorted().prefix(64).map { $0 }
            let folded = text.lowercased()
            // Overlapping rhetorical cues, not scientific judgements or an exhaustive taxonomy.
            var purposes: [Intent] = []
            func has(_ expression: String) -> Bool { folded.range(of: expression, options: .regularExpression) != nil }
            if has(#"\b(recent|trend|increasing|increasingly|review|widespread|widely)\w*\b"#) { purposes.append(.background) }
            if has(#"\b(mechanism|reactivity|reaction|ignition|pressure|temperature|cause|because|due|weak|strong)\w*\b"#) { purposes.append(.foundation) }
            if has(#"\b(using|used|use|implement|algorithm|software|solver|tool|based|modelled|modeled)\w*\b"#) { purposes.append(.method) }
            if has(#"\b(compar|validat|benchmark|agreement|agree|error|outperform|accuracy|higher|lower|measured)\w*\b"#) { purposes.append(.comparison) }
            intents = purposes.isEmpty ? [.unclear] : purposes
        }
    }
    private static let stop = Set("a an and are as at be been being by can could did do does for from had has have how if in into is it its may more most of on or our should so than that the their these they this those through to using use used uses was we were which while with would study studies research results method methods show shows suggest suggests observed observation observations well known much many also respectively et al recently".split(separator: " ").map(String.init))
    private static let commands = try! NSRegularExpression(pattern: #"\\(?:cite|citep|citet|parencite|textcite|autocite|footcite|smartcite|nocite|ref|label)\*?(?:\[[^\]]*\])*\{[^}]*\}|\\[A-Za-z]+\*?"#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?(?:e[+-]?\d+)?\b"#)
    private static let sentenceBoundary = try! NSRegularExpression(pattern: #"[.!?]\s+(?=[A-Z])"#)
    static func sameSource(_ a: ReferenceRecord, _ b: ReferenceRecord) -> Bool {
        let doiA = ReferenceDuplicates.normaliseDOI(a.fields["doi"] ?? ""), doiB = ReferenceDuplicates.normaliseDOI(b.fields["doi"] ?? "")
        if !doiA.isEmpty && !doiB.isEmpty { return doiA.hasPrefix("10.") && doiA.contains("/") && doiA == doiB }
        let archiveA = ReferenceRecognition.archiveID(a).map(ReferenceArxiv.base), archiveB = ReferenceRecognition.archiveID(b).map(ReferenceArxiv.base)
        if let archiveA, let archiveB { return archiveA == archiveB }
        func normalise(_ value: String) -> String {
            ReferenceText.display(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
        }
        let title = normalise(a.title), author = normalise(a.contributors)
        return title.count >= 20 && title == normalise(b.title) && !author.isEmpty && a.usesEditors == b.usesEditors && author == normalise(b.contributors) && !a.year.isEmpty && a.year == b.year
    }
    static func plain(_ value: String) -> String {
        let value = commands.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " ")
        return value.replacingOccurrences(of: "~", with: " ").replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " ")
    }
    static func tokens(_ value: String) -> [String] {
        var value = plain(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        // Expand a small, explicit vocabulary on both sides. No inferred scientific equivalences.
        for (short, long) in [("ml", "machine learning"), ("dnn", "deep neural network"), ("dnns", "deep neural networks")] {
            value = value.replacingOccurrences(of: "\\b" + short + "\\b", with: long, options: .regularExpression)
        }
        let numbers = numberPattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { "#" + (value as NSString).substring(with: $0.range) }
        return numbers + value.components(separatedBy: CharacterSet.alphanumerics.inverted).compactMap {
            guard !stop.contains($0), !$0.allSatisfy(\.isNumber) else { return nil }
            var word = $0
            if word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("is") { word.removeLast() }
            return word.count >= 2 && !stop.contains(word) ? word : nil
        }
    }
    static func sentence(_ source: String, before location: Int) -> String {
        let raw = source as NSString
        guard location > 0, location <= raw.length else { return "" }
        let start = max(0, location - 2048)
        var text = raw.substring(with: NSRange(location: start, length: location - start))
        if let cite = text.range(of: #"\\(?:cite|citep|citet|parencite|textcite|autocite|footcite|smartcite|nocite)\*?(?:\[[^\]]*\])*\{[^{}]*$"#, options: .regularExpression) { text.removeSubrange(cite) }
        text = text.replacingOccurrences(of: #"(?m)(?<!\\)%[^\n]*"#, with: "", options: .regularExpression)
        text = plain(text).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        if let paragraph = text.range(of: "\n\n", options: .backwards) { text = String(text[paragraph.upperBound...]) }
        if let last = sentenceBoundary.matches(in: text, range: NSRange(text.startIndex..., in: text)).last {
            text = (text as NSString).substring(from: last.range.location + last.range.length)
        }
        return String(text.suffix(1200)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func score(_ document: Document, context: Context, frequencies: [String: Int], count: Int) -> Double {
        guard context.terms.count >= 2 else { return 0 }
        var score = 0.0
        for term in context.terms {
            guard let frequency = document.terms[term] else { continue }
            let idf = log(1 + Double(count + 1) / Double((frequencies[term] ?? 0) + 1))
            score += idf * (document.title.contains(term) ? 2 : 1) * Double(frequency) / (Double(frequency) + 0.5 + Double(document.terms.count) / 150)
        }
        return score
    }
    static func assess(_ document: Document, context: Context) -> Assessment? {
        guard context.terms.count >= 2 else { return nil }
        let matched = context.terms.filter { document.terms[$0] != nil }
        let coverage = Double(matched.count) / Double(context.terms.count)
        let label = matched.count >= 2 && coverage >= 0.35 ? "Topic match" : matched.isEmpty ? "No clear match" : "Limited overlap"
        let sentences = document.abstract.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let wanted = Set(context.terms)
        let best = sentences.map { (text: $0, matches: Set(tokens($0)).intersection(wanted).count) }.max { $0.matches < $1.matches }
        let excerpt = best.map { $0.matches > 0 ? $0.text : "" } ?? ""
        return Assessment(label: label, basis: document.abstract.isEmpty ? "Title only" : "Title and abstract", intents: context.intents, matched: matched, excerpt: String(excerpt.prefix(220)))
    }
}
