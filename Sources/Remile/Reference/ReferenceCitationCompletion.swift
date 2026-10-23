import Foundation
import CryptoKit

/// Project-local preferences stay outside the manuscript and travel through neither Git nor Live.
enum ReferenceCitationPreferences {
    struct Choice: Codable { var library: UUID?; var bibliography: String? }
    static func key(_ context: String) -> String { "reference.citation." + SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func read(_ context: String, store: UserDefaults = .standard) -> Choice {
        guard let data = store.data(forKey: key(context)), let choice = try? JSONDecoder().decode(Choice.self, from: data) else { return Choice() }
        return choice
    }
    static func write(_ choice: Choice, context: String, store: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(choice) { store.set(data, forKey: key(context)) }
    }
    static func destination(_ files: [String], preferred: String?) -> String? {
        if let preferred, files.contains(preferred) { return preferred }
        return files.count == 1 ? files[0] : files.isEmpty ? "remile-references.bib" : nil
    }
}

enum ReferenceCitationCompletion {
    struct Prefix { let range: NSRange; let query: String; let closing: String }
    struct Suggestion { let record: ReferenceRecord; let project: Bool }
    private static let expression = try! NSRegularExpression(pattern: #"(?<!\\)\\(?:cite|citep|citet|parencite|textcite|autocite|footcite|smartcite|nocite)\*?(?:\[[^\]\r\n]*\]){0,2}\{([^{}\r\n]*)$"#)
    static func prefix(_ source: String, selection: NSRange) -> Prefix? {
        let source = source as NSString
        guard selection.length == 0, selection.location > 0, selection.location <= source.length else { return nil }
        // Work on the current line only, with a bounded look-behind.
        let start = max(0, selection.location - 1024)
        let suffix = source.substring(with: NSRange(location: start, length: selection.location - start))
        let line = suffix.components(separatedBy: "\n").last ?? ""
        let units = Array(line.utf16)
        for i in units.indices where units[i] == 37 {
            var j = i
            while j > 0 && units[j - 1] == 92 { j -= 1 }
            if (i - j).isMultiple(of: 2) { return nil }
        }
        let raw = line as NSString
        guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: raw.length)) else { return nil }
        let keys = raw.substring(with: match.range(at: 1)), fragment = keys.components(separatedBy: ",").last ?? ""
        let query = fragment.trimmingCharacters(in: .whitespaces)
        guard query.utf16.count <= 160 else { return nil }
        // Preserve preceding keys and whitespace, consume an existing brace only once.
        let replacement = fragment.drop(while: { $0.isWhitespace })
        let length = (String(replacement) as NSString).length
        var end = selection.location
        while end < source.length, end - selection.location < 160 {
            let unit = source.character(at: end)
            if unit == 125 || unit == 44 || [9, 10, 13, 32].contains(unit) { break }
            end += 1
        }
        // A comma belongs to the remaining citation list, never close the group ahead of it.
        let next = end < source.length ? source.character(at: end) : 0
        let closing = next == 44 ? "" : "}"
        if next == 125 { end += 1 }
        return Prefix(range: NSRange(location: selection.location - length, length: length + end - selection.location), query: query, closing: closing)
    }
    static func suggestions(query: String, project: [ReferenceRecord], library: [ReferenceRecord], limit: Int = 8) -> [Suggestion] {
        suggestions(query: query, project: ReferenceCitationIndex(project), library: ReferenceCitationIndex(library), limit: limit)
    }
    static func suggestions(query: String, project: ReferenceCitationIndex, library: ReferenceCitationIndex, limit: Int = 8) -> [Suggestion] {
        let limit = max(0, min(50, limit))
        guard limit > 0 else { return [] }
        let query = ReferenceCitationIndex.fold(query), words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var result: [Suggestion] = [], keys = Set<String>()
        for (index, local) in [(project, true), (library, false)] {
            for prefix in [true, false] {
                for entry in index.entries where entry.key.hasPrefix(query) == prefix && words.allSatisfy({ entry.search.contains($0) }) {
                    guard keys.insert(entry.record.citationKey).inserted else { continue }
                    result.append(Suggestion(record: entry.record, project: local))
                    if result.count == limit { return result }
                }
            }
        }
        return result
    }
}

/// Prepared off the typing path, reused by the editor and the reference picker.
struct ReferenceCitationIndex: Sendable {
    struct Entry: Sendable { let record: ReferenceRecord; let key: String; let search: String }
    let entries: [Entry]
    init(_ records: [ReferenceRecord] = [], byTitle: Bool = false) {
        entries = records.filter { ReferenceBibTeX.validToken($0.citationKey) }.sorted {
            (byTitle ? $0.displayTitle : $0.citationKey).localizedStandardCompare(byTitle ? $1.displayTitle : $1.citationKey) == .orderedAscending
        }.map { record in
            var record = record; record.originalCitation = ""
            return Entry(record: record, key: Self.fold(record.citationKey), search: Self.fold([record.citationKey, record.displayTitle, record.displayAuthors, record.year].joined(separator: " ")))
        }
    }
    static func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
    var count: Int { entries.count }
}
