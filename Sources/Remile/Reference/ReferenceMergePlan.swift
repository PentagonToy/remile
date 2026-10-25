import Foundation

/// A local recommendation. Publication status is inferred from stored fields, not externally verified.
enum ReferenceMergePlan {
    static func ranked(_ records: [ReferenceRecord]) -> [ReferenceRecord] {
        records.sorted {
            let left = score($0), right = score($1)
            if left != right { return left > right }
            if $0.created != $1.created { return $0.created < $1.created }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    static func status(_ record: ReferenceRecord) -> String {
        if published(record) { return "Published record" }
        if preprint(record) { return "Preprint" }
        return "Reference"
    }
    static func fields(_ records: [ReferenceRecord], preferred: UUID) -> [String: String] {
        let ordered = ranked(records)
        guard let master = records.first(where: { $0.id == preferred }) else { return [:] }
        var fields = master.fields
        for record in ordered {
            for (key, value) in record.fields where fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                if published(master) && preprint(record) && ["journal", "booktitle", "publisher", "volume", "number", "pages", "year", "doi", "url"].contains(key) { continue }
                fields[key] = value
            }
        }
        // Prefer a readable spelling of the same title. Do not turn an unrelated title into a spelling correction.
        if let original = fields["title"], allCaps(original), let better = ordered.compactMap({ $0.fields["title"] }).first(where: { !allCaps($0) && identity($0) == identity(original) }) { fields["title"] = better }
        let keywords = ordered.compactMap { $0.fields["keywords"] }.flatMap { $0.components(separatedBy: ",") }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !keywords.isEmpty { fields["keywords"] = Array(Set(keywords)).sorted().joined(separator: ", ") }
        return fields
    }
    static func conflicts(_ records: [ReferenceRecord]) -> [String] {
        Set(records.flatMap { $0.fields.keys }).filter { field in
            field != "abstract" && field != "note" && field != "keywords" && Set(records.compactMap { $0.fields[field] }.filter { !$0.isEmpty }).count > 1
        }.sorted { a, b in
            let order = ["title", "author", "year", "journal", "booktitle", "publisher", "volume", "number", "pages", "doi"]
            return (order.firstIndex(of: a) ?? 100, a) < (order.firstIndex(of: b) ?? 100, b)
        }
    }
    private static func score(_ record: ReferenceRecord) -> Int {
        let populated = ["title", "author", "year", "journal", "booktitle", "publisher", "volume", "number", "pages", "doi", "isbn", "issn", "url"].filter { record.fields[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.count
        return (published(record) ? 10_000 : preprint(record) ? 0 : 5_000) + (record.fields["doi"]?.hasPrefix("10.") == true ? 500 : 0) + (record.attachments.isEmpty ? 0 : 200) + populated
    }
    static func published(_ record: ReferenceRecord) -> Bool {
        if record.fields["entrysubtype"] == "preprint" { return false }
        if record.type == "article", let journal = record.fields["journal"], !journal.isEmpty { return !isArchive(journal) }
        return ["inproceedings", "conference", "book", "inbook", "incollection"].contains(record.type) && !preprint(record) && ["publisher", "booktitle"].contains { record.fields[$0]?.isEmpty == false }
    }
    private static func preprint(_ record: ReferenceRecord) -> Bool {
        let venue = record.fields["journal"] ?? ""
        if isArchive(venue) || record.fields["entrysubtype"] == "preprint" { return true }
        return venue.isEmpty && (record.fields["eprint"]?.isEmpty == false || isArchive(record.fields["archiveprefix"] ?? "") || record.type == "unpublished")
    }
    private static func isArchive(_ value: String) -> Bool { ["arxiv", "biorxiv", "medrxiv", "ssrn", "preprint", "research square"].contains { value.localizedCaseInsensitiveContains($0) } }
    private static func identity(_ value: String) -> String { ReferenceText.display(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).components(separatedBy: CharacterSet.alphanumerics.inverted).joined() }
    private static func allCaps(_ value: String) -> Bool { let value = ReferenceText.display(value); return value.rangeOfCharacter(from: .letters) != nil && value == value.uppercased() }
}
