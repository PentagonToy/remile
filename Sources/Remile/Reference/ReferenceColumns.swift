import Foundation

enum ReferenceColumn: String, CaseIterable, Identifiable {
    case title, author, publication, year, publisher, key, type, added
    static let preference = "reference.columns"
    static let defaults = "title,author,publication,year,type"
    static func applyDefaults(_ store: UserDefaults = .standard) {
        let migration = "reference.columns.typeDefault"
        guard !store.bool(forKey: migration) else { return }
        if store.string(forKey: preference) == nil || store.string(forKey: preference) == "title,author,publication,year" { store.set(defaults, forKey: preference) }
        store.set(true, forKey: migration)
    }
    var id: String { rawValue }
    var label: String { switch self { case .title: "Title"; case .author: "Author / Editor"; case .year: "Year"; case .publisher: "Publisher"; case .publication: "Journal / Publisher"; case .key: "Citation key"; case .type: "Type"; case .added: "Date added" } }
    var width: Double { switch self { case .year: 48; case .author: 112; case .publication: 150; case .added: 98; case .type: 110; default: 130 } }
    func value(_ record: ReferenceRecord) -> String {
        switch self {
        case .title: record.displayTitle
        case .author: record.shortContributors
        case .year: record.year
        case .publisher: ReferenceText.display(record.fields["publisher"] ?? "")
        case .publication: ["journal", "booktitle", "publisher"].compactMap { record.fields[$0] }.map(ReferenceText.display).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        case .key: record.citationKey
        case .type: ReferenceKind.classify(record).label
        case .added: record.created.formatted(date: .abbreviated, time: .omitted)
        }
    }
    static func visible(_ source: String) -> [Self] { [.title] + allCases.filter { $0 != .title && source.split(separator: ",").contains(Substring($0.rawValue)) } }
}
enum ReferenceExport {
    static let abstractPreference = "reference.exportAbstract"
    static func bibtex(_ records: [ReferenceRecord], includeAbstract: Bool = UserDefaults.standard.bool(forKey: abstractPreference)) throws -> String {
        try ReferenceBibTeX.export(records.map { record in var copy = record; if !includeAbstract { copy.fields.removeValue(forKey: "abstract") }; return copy })
    }
}

/// Native headings and CLI lists share the same stable ordering.
struct ReferenceSort {
    var column: ReferenceColumn = .title
    var ascending = true
    mutating func select(_ column: ReferenceColumn) {
        if self.column == column { ascending.toggle() }
        else { self.column = column; ascending = true }
    }
    func sorted(_ records: [ReferenceRecord]) -> [ReferenceRecord] {
        let prepared = records.enumerated().map { index, record in
            (record: record, index: index, text: (column == .author ? ReferenceText.display(record.contributors) : column.value(record)).trimmingCharacters(in: .whitespacesAndNewlines), title: record.displayTitle)
        }
        return prepared.sorted { left, right in
            // Missing values stay below populated values in both directions.
            if left.text.isEmpty != right.text.isEmpty { return !left.text.isEmpty }
            var comparison: ComparisonResult
            if column == .added { comparison = left.record.created.compare(right.record.created) }
            else if column == .year {
                let a = Int(left.text), b = Int(right.text)
                if (a != nil) != (b != nil) { return a != nil }
                if let a, let b { comparison = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending }
                else { comparison = left.text.localizedStandardCompare(right.text) }
            }
            else { comparison = left.text.localizedStandardCompare(right.text) }
            if comparison != .orderedSame { return ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
            let title = left.title.localizedStandardCompare(right.title)
            if title != .orderedSame { return title == .orderedAscending }
            return left.index < right.index
        }.map(\.record)
    }
}

enum ReferenceColumnWidths {
    static let preference = "reference.columnWidths"
    static func clamp(_ value: Double, column: ReferenceColumn) -> Double { min(column == .title ? 1200 : 600, max(column == .title ? 180 : 44, value)) }
    static func decode(_ source: String) -> [String: Double] {
        guard source.utf8.count <= 4096, let data = source.data(using: .utf8), let values = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return values.reduce(into: [:]) { result, entry in
            if let column = ReferenceColumn(rawValue: entry.key), entry.value.isFinite { result[entry.key] = clamp(entry.value, column: column) }
        }
    }
    static func encode(_ values: [String: Double]) -> String { (try? JSONEncoder().encode(values)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }
}
