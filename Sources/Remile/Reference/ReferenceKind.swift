import Foundation

enum ReferenceKind: String, CaseIterable {
    case article, book, newspaper, webpage, conference, report, preprint
    case mastersThesis = "mastersthesis"
    case doctoralThesis = "phdthesis"
    case note, other
    var symbol: String {
        switch self {
        case .article: return "doc.text"
        case .book: return "book.closed"
        case .newspaper: return "newspaper"
        case .webpage: return "globe"
        case .conference: return "doc" // Fallback when the custom podium asset is unavailable.
        case .report: return "doc.richtext"
        case .preprint: return "doc.plaintext"
        case .note: return "scribble.variable"
        case .other: return "doc"
        case .mastersThesis, .doctoralThesis: return "graduationcap"
        }
    }
    var label: String {
        switch self {
        case .article: return "Journal article"
        case .book: return "Book"
        case .newspaper: return "Newspaper article"
        case .webpage: return "Web page"
        case .conference: return "Conference paper"
        case .report: return "Report"
        case .preprint: return "Preprint"
        case .note: return "Note"
        case .other: return "Other"
        case .mastersThesis: return "Thesis"
        case .doctoralThesis: return "Dissertation"
        }
    }
    var bibType: String {
        switch self {
        case .article, .newspaper: return "article"
        case .book: return "book"
        case .webpage: return "online"
        case .conference: return "inproceedings"
        case .report: return "techreport"
        case .note: return "unpublished"
        case .preprint, .other: return "misc"
        case .mastersThesis: return "mastersthesis"
        case .doctoralThesis: return "phdthesis"
        }
    }
    static func classify(_ record: ReferenceRecord) -> Self {
        if record.type == "unpublished", record.fields["entrysubtype"]?.lowercased() == "note" { return .note }
        if record.fields["entrysubtype"]?.lowercased() == "preprint" { return .preprint }
        let type = record.type.lowercased()
        if let kind = thesisKind(type) { return kind }
        if type == "thesis", let kind = thesisKind(record.fields["type"] ?? "") { return kind }
        if type == "article" { return record.fields["entrysubtype"]?.lowercased() == "newspaper" ? .newspaper : .article }
        if ["book", "inbook", "incollection", "booklet"].contains(type) { return .book }
        if ["online", "www", "electronic", "webpage", "website", "url"].contains(type) { return .webpage }
        if ["newspaper", "news"].contains(type) { return .newspaper }
        if ["inproceedings", "conference", "proceedings"].contains(type) { return .conference }
        if ["report", "techreport"].contains(type) { return .report }
        return .other
    }
    static func thesisKind(_ value: String) -> Self? {
        let value = value.lowercased().filter(\.isLetter)
        if ["mastersthesis", "masterthesis", "mathesis", "masterofscience", "masterofarts", "masterofengineering", "masters", "master", "msc", "mscthesis"].contains(value) { return .mastersThesis }
        if ["phdthesis", "phddissertation", "phd", "doctoralthesis", "doctoraldissertation", "doctorofphilosophy"].contains(value) { return .doctoralThesis }
        return nil
    }
    func applying(to record: ReferenceRecord, customType: String = "") -> ReferenceRecord {
        var result = record
        result.type = self == .other ? (customType.isEmpty ? "misc" : customType) : bibType
        if self == .note { result.fields["entrysubtype"] = "note" }
        else if self == .preprint { result.fields["entrysubtype"] = "preprint" }
        else if self == .newspaper { result.fields["entrysubtype"] = "newspaper" }
        else if ["newspaper", "preprint", "note", "pdf"].contains(result.fields["entrysubtype"] ?? "") { result.fields.removeValue(forKey: "entrysubtype") }
        if self == .mastersThesis { result.fields["type"] = "Master's thesis" }
        else if self == .doctoralThesis { result.fields["type"] = "PhD dissertation" }
        else if Self.thesisKind(result.fields["type"] ?? "") != nil { result.fields.removeValue(forKey: "type") }
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
        if let school = record.fields["school"], !school.isEmpty { result.append(.init(id: "school", label: "University", value: school)) }
        let known = Set(names.map(\.0) + ["entrysubtype", "abstract", "school"] + (ReferenceKind.thesisKind(record.type) != nil || record.type == "thesis" ? ["type"] : []))
        for key in record.fields.keys.sorted() where !known.contains(key) {
            if let value = record.fields[key], !value.isEmpty { result.append(ReferenceMetadataRow(id: key, label: key.replacingOccurrences(of: "_", with: " ").capitalized, value: value)) }
        }
        result.append(ReferenceMetadataRow(id: "created", label: "Date added", value: record.created.formatted(date: .abbreviated, time: .omitted)))
        result.append(ReferenceMetadataRow(id: "modified", label: "Modified", value: record.modified.formatted(date: .abbreviated, time: .shortened)))
        if let value = record.fields["abstract"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(ReferenceMetadataRow(id: "abstract", label: "Abstract", value: value))
        }
        return result
    }
}
