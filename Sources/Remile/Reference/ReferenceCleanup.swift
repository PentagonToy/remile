import Foundation
import PDFKit

/// Reversible formatting proposals. Applying them is an explicit, revision-checked action.
enum ReferenceCleanup {
    struct Change: Identifiable, Sendable {
        let before: ReferenceRecord
        let after: ReferenceRecord
        var id: UUID { before.id }
        var fields: [String] { (Set(before.fields.keys).union(after.fields.keys).filter { before.fields[$0] != after.fields[$0] } + (before.type != after.type ? ["@type"] : [])).sorted() }
    }
    static func needsLookup(_ record: ReferenceRecord) -> Bool {
        ReferenceRecognition.eligible(record) && (record.contributors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || record.year.isEmpty || (record.fields["abstract"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    /// Preview only. Applying keeps the existing revision check and Undo boundary.
    static func onlineChange(_ before: ReferenceRecord, local: ReferenceRecord, fetched: ReferenceRecord) throws -> Change? {
        let after = try ReferenceRecognition.merged(local, with: fetched)
        return after.fields == before.fields && after.type == before.type ? nil : Change(before: before, after: after)
    }
    static func proposals(_ records: [ReferenceRecord], repository: ReferenceRepository) throws -> [Change] {
        var result: [Change] = [], cached: [UUID: [String: String]] = [:]
        for record in records where record.trashed == nil {
            try Task.checkCancellation()
            var next = record
            for field in ["title", "author", "editor", "journal", "booktitle", "publisher", "year", "volume", "number", "pages", "doi", "url", "isbn", "issn"] {
                if let value = next.fields[field] { next.fields[field] = value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            }
            if let doi = next.fields["doi"], !doi.isEmpty { next.fields["doi"] = ReferenceDuplicates.normaliseDOI(doi) }
            for attachment in record.attachments where next.fields["doi"]?.isEmpty != false || next.authors.isEmpty || ReferencePDFMetadata.placeholderTitle(next.title) || next.title == attachment.name || next.title == (attachment.name as NSString).deletingPathExtension {
                let fields: [String: String]
                if let saved = cached[attachment.id] { fields = saved }
                else {
                    let url = repository.attachmentURL(attachment)
                    guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= 200_000_000 }) == true, let pdf = PDFDocument(url: url), !pdf.isLocked else { continue }
                    fields = ReferencePDFMetadata.fields(pdf, fallback: (attachment.name as NSString).deletingPathExtension)
                    cached[attachment.id] = fields
                }
                for (field, value) in fields where next.fields[field]?.isEmpty != false || (field == "title" && (ReferencePDFMetadata.placeholderTitle(next.title) || next.title == attachment.name || next.title == (attachment.name as NSString).deletingPathExtension)) { next.fields[field] = value }
            }
            if next.fields["archiveprefix"]?.lowercased() == "arxiv", next.fields["journal"]?.isEmpty != false, next.type == "article" { next.type = "misc" }
            if next.fields != record.fields || next.type != record.type { result.append(Change(before: record, after: next)) }
        }
        return result
    }
}
