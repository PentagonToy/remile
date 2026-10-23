import Foundation

enum ReferenceKind: String, CaseIterable {
    case article, book, newspaper, webpage, conference, other
    var label: String {
        switch self {
        case .article: return "Journal article"
        case .book: return "Book"
        case .newspaper: return "Newspaper article"
        case .webpage: return "Web page"
        case .conference: return "Conference paper"
        case .other: return "Other"
        }
    }
    var bibType: String {
        switch self {
        case .article, .newspaper: return "article"
        case .book: return "book"
        case .webpage: return "online"
        case .conference: return "inproceedings"
        case .other: return "misc"
        }
    }
    static func classify(_ record: ReferenceRecord) -> Self {
        let type = record.type.lowercased()
        if type == "article" { return record.fields["entrysubtype"]?.lowercased() == "newspaper" ? .newspaper : .article }
        if ["book", "inbook", "incollection", "booklet"].contains(type) { return .book }
        if ["online", "www", "electronic"].contains(type) { return .webpage }
        if ["inproceedings", "conference", "proceedings"].contains(type) { return .conference }
        return .other
    }
    func applying(to record: ReferenceRecord, customType: String = "") -> ReferenceRecord {
        var result = record
        result.type = self == .other ? (customType.isEmpty ? "misc" : customType) : bibType
        if self == .newspaper { result.fields["entrysubtype"] = "newspaper" }
        else if result.fields["entrysubtype"] == "newspaper" { result.fields.removeValue(forKey: "entrysubtype") }
        return result
    }
}

struct ReferenceMetadataRow: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}
enum ReferenceMetadata {
    static func rows(_ record: ReferenceRecord) -> [ReferenceMetadataRow] {
        let names: [(String, String)] = [("title", "Title"), ("author", "Author"), ("year", "Year"), ("date", "Date"), ("journal", "Publication"), ("booktitle", "Book / proceedings"), ("editor", "Editor"), ("publisher", "Publisher"), ("institution", "Institution"), ("organization", "Organisation"), ("volume", "Volume"), ("number", "Issue"), ("edition", "Edition"), ("series", "Series"), ("chapter", "Chapter"), ("pages", "Pages"), ("address", "Place"), ("location", "Location"), ("language", "Language"), ("shorttitle", "Short title"), ("doi", "DOI"), ("isbn", "ISBN"), ("issn", "ISSN"), ("pmid", "PMID"), ("pmcid", "PMCID"), ("eprint", "Archive ID"), ("archiveprefix", "Archive"), ("license", "Licence"), ("url", "URL"), ("urldate", "Accessed"), ("keywords", "Keywords"), ("note", "Notes")]
        var result = [ReferenceMetadataRow(id: "key", label: "Citation key", value: record.citationKey), ReferenceMetadataRow(id: "kind", label: "Type", value: ReferenceKind.classify(record) == .other ? record.type : ReferenceKind.classify(record).label)]
        for (key, label) in names {
            if let value = record.fields[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(ReferenceMetadataRow(id: key, label: label, value: ReferenceText.field(key, value))) }
        }
        let known = Set(names.map(\.0) + ["entrysubtype", "abstract"])
        for key in record.fields.keys.sorted() where !known.contains(key) {
            if let value = record.fields[key], !value.isEmpty { result.append(ReferenceMetadataRow(id: key, label: key.replacingOccurrences(of: "_", with: " ").capitalized, value: value)) }
        }
        result.append(ReferenceMetadataRow(id: "created", label: "Date added", value: record.created.formatted(date: .abbreviated, time: .omitted)))
        result.append(ReferenceMetadataRow(id: "modified", label: "Modified", value: record.modified.formatted(date: .abbreviated, time: .shortened)))
        return result
    }
}
