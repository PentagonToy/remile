import Foundation
import CryptoKit

/// Project-local preferences stay outside the manuscript and travel through neither Git nor Live.
enum ReferenceCitationPreferences {
    struct Choice: Codable {
        var library: UUID?
        var bibliography: String?
        var libraries: [UUID]?
        var selectedLibraries: Set<UUID> { Set(libraries ?? library.map { [$0] } ?? []) }
    }
    static func includes(_ record: ReferenceRecord, libraries: Set<UUID>) -> Bool { libraries.contains(record.library) || record.collectionID.map(libraries.contains) == true }
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
    struct Prefix: Sendable { let range: NSRange; let query: String; let closing: String }
    struct Suggestion: Sendable { let record: ReferenceRecord; let project: Bool; var relevance: ReferenceRelevance.Assessment? = nil }
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
    static func suggestions(query: String, project: [ReferenceRecord], library: [ReferenceRecord], limit: Int = 8, context: String = "") -> [Suggestion] {
        suggestions(query: query, project: ReferenceCitationIndex(project), library: ReferenceCitationIndex(library), limit: limit, context: context)
    }
    static func suggestions(query: String, project: ReferenceCitationIndex, library: ReferenceCitationIndex, limit: Int = 8, context: String = "") -> [Suggestion] {
        let limit = max(0, min(50, limit))
        guard limit > 0 else { return [] }
        let query = ReferenceCitationIndex.fold(query), words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let queryTerms = ReferenceRelevance.tokens(query)
        let context = ReferenceRelevance.Context(context)
        let frequencies = project.frequencies.merging(library.frequencies, uniquingKeysWith: +)
        let count = project.count + library.count
        let libraryByKey = Dictionary(grouping: library.entries, by: { $0.record.citationKey })
        var matches: [(entry: ReferenceCitationIndex.Entry, document: ReferenceRelevance.Document, local: Bool, priority: Int, score: Double)] = []
        var keys = Set<String>()
        for (index, local) in [(project, true), (library, false)] {
            for entry in index.entries {
                guard !Task.isCancelled else { return [] }
                var document = entry.document
                var borrowedSearch: String?
                if local, document.abstract.isEmpty {
                    let enriched = (libraryByKey[entry.record.citationKey] ?? []).filter { ReferenceRelevance.sameSource(entry.record, $0.record) }
                    if enriched.count == 1 { document = enriched[0].document; borrowedSearch = entry.metadata + " " + ReferenceCitationIndex.fold(document.abstract) }
                }
                let priority: Int
                if entry.key.hasPrefix(query) { priority = 0 }
                else if words.allSatisfy({ entry.metadata.contains($0) }) { priority = 1 }
                else if words.allSatisfy({ entry.search.contains($0) }) { priority = 2 }
                else if let borrowedSearch, words.allSatisfy({ borrowedSearch.contains($0) }) { priority = 2 }
                else if !queryTerms.isEmpty && queryTerms.allSatisfy({ document.terms[$0] != nil }) { priority = 2 }
                else { continue }
                guard keys.insert(entry.record.citationKey).inserted else { continue }
                matches.append((entry, document, local, priority, ReferenceRelevance.score(document, context: context, frequencies: frequencies, count: count)))
            }
        }
        return matches.sorted {
            if context.terms.count < 2, $0.local != $1.local { return $0.local }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.local != $1.local { return $0.local }
            return $0.entry.key < $1.entry.key
        }.prefix(limit).map {
            Suggestion(record: $0.entry.record, project: $0.local, relevance: ReferenceRelevance.assess($0.document, context: context))
        }
    }
}

/// Prepared off the typing path, reused by the editor and the reference picker.
struct ReferenceCitationIndex: Sendable {
    struct Entry: Sendable { let record: ReferenceRecord; let key: String; let metadata: String; let search: String; let document: ReferenceRelevance.Document }
    let entries: [Entry]
    let frequencies: [String: Int]
    init(_ records: [ReferenceRecord] = [], byTitle: Bool = false) {
        entries = records.filter { ReferenceBibTeX.validToken($0.citationKey) }.sorted {
            (byTitle ? $0.displayTitle : $0.citationKey).localizedStandardCompare(byTitle ? $1.displayTitle : $1.citationKey) == .orderedAscending
        }.map { record in
            var record = record; record.originalCitation = ""
            let title = ReferenceText.display(String(record.title.prefix(2000)))
            let metadata = Self.fold([record.citationKey, title, String(record.displayContributors.prefix(2000)), record.year].joined(separator: " "))
            let plainAbstract = ReferenceText.display(String((record.fields["abstract"] ?? "").prefix(12_000)))
            let abstract = Self.fold(plainAbstract)
            return Entry(record: record, key: Self.fold(record.citationKey), metadata: metadata, search: abstract.isEmpty ? metadata : metadata + " " + abstract, document: ReferenceRelevance.Document(title: title, abstract: plainAbstract))
        }
        frequencies = entries.reduce(into: [:]) { result, entry in
            for term in entry.document.terms.keys { result[term, default: 0] += 1 }
        }
    }
    static func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
    var count: Int { entries.count }
}
