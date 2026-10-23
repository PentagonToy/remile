import Foundation

enum ReferenceColumn: String, CaseIterable, Identifiable {
    case title, author, publication, year, publisher, key, type, added
    static let preference = "reference.columns"
    static let defaults = "title,author,publication,year"
    var id: String { rawValue }
    var label: String { switch self { case .title: "Title"; case .author: "Author"; case .year: "Year"; case .publisher: "Publisher"; case .publication: "Journal / Publisher"; case .key: "Citation key"; case .type: "Type"; case .added: "Date added" } }
    var width: Double { switch self { case .year: 48; case .author: 112; case .publication: 190; case .added: 98; case .type: 110; default: 130 } }
    func value(_ record: ReferenceRecord) -> String {
        switch self {
        case .title: record.displayTitle
        case .author: ReferenceText.shortAuthors(record.authors)
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
