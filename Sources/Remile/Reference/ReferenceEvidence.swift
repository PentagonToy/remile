import Foundation
import CryptoKit
import PDFKit

/// Resolve identity before exposing an attachment. A matching key alone is not proof of identity.
enum ReferenceEvidence {
    static func key(in source: String, selection: NSRange) -> String? {
        let caret = NSRange(location: selection.location, length: 0)
        guard let prefix = ReferenceCitationCompletion.prefix(source, selection: caret) else { return nil }
        let raw = source as NSString
        var end = selection.location
        while end < raw.length, end - selection.location < 160 {
            let unit = raw.character(at: end)
            if [9, 10, 13, 32, 44, 125].contains(unit) { break }
            end += 1
        }
        let key = prefix.query + raw.substring(with: NSRange(location: selection.location, length: end - selection.location))
        return ReferenceBibTeX.validToken(key) ? key : nil
    }
    static func page(recordID: UUID, attachmentID: UUID, page: Int, repository: ReferenceRepository = ReferenceRepository()) throws -> [String: Any] {
        let loaded = try attachment(recordID: recordID, attachmentID: attachmentID, repository: repository)
        guard let pdf = PDFDocument(data: loaded.data), !pdf.isLocked, pdf.allowsCopying, page > 0, page <= pdf.pageCount, let source = pdf.page(at: page - 1)?.string else { throw ReferenceFailure("Choose a readable PDF page. Scanned or restricted PDFs may have no extractable text.") }
        return ["ok": true, "schema": 1, "id": recordID.uuidString, "revision": loaded.record.revision.uuidString, "attachment": attachmentID.uuidString, "sha256": loaded.attachment.sha256, "key": loaded.record.citationKey, "page": page, "pages": pdf.pageCount, "location": "PDF page " + String(page), "text": String(source.prefix(12000)), "truncated": source.count > 12000]
    }
    static func active(_ repository: ReferenceRepository) throws -> [ReferenceRecord] {
        let snapshot = try repository.snapshot(), hidden = Set(snapshot.libraries.filter { $0.trashed != nil }.map(\.id))
        return snapshot.records.filter { $0.trashed == nil && !hidden.contains($0.library) && $0.collectionID.map(hidden.contains) != true }
    }
    static func resolve(key: String, sources: [String: String], library: UUID?, repository: ReferenceRepository = ReferenceRepository()) throws -> ReferenceRecord {
        guard ReferenceBibTeX.validToken(key) else { throw ReferenceFailure("Choose a citation key.") }
        let local = try sources.keys.sorted().filter { $0.lowercased().hasSuffix(".bib") }.flatMap { path -> [ReferenceRecord] in
            let source = sources[path]!
            return source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : try ReferenceBibTeX.parse(source).filter { $0.citationKey == key }
        }
        if let first = local.first {
            let canonical = try ReferenceExport.bibtex([first], includeAbstract: false)
            guard try local.allSatisfy({ try ReferenceExport.bibtex([$0], includeAbstract: false) == canonical }) else { throw ReferenceFailure("This key has different entries in the project bibliographies.") }
            let matches = try active(repository).filter { candidate in
                (library == nil || candidate.library == library || candidate.collectionID == library) && candidate.citationKey == key && (try? ReferenceExport.bibtex([candidate], includeAbstract: false)) == canonical
            }
            // Unmatched project entries still have metadata, but never borrow a PDF by key alone.
            return matches.count == 1 ? matches[0] : first
        }
        let matches = try active(repository).filter { $0.citationKey == key && (library == nil || $0.library == library || $0.collectionID == library) }
        guard matches.count == 1 else { throw ReferenceFailure(matches.isEmpty ? "This reference is not in the project or selected library." : "This key belongs to several references. Choose a library first.") }
        return matches[0]
    }
    static func attachment(recordID: UUID, attachmentID: UUID, repository: ReferenceRepository = ReferenceRepository()) throws -> (record: ReferenceRecord, attachment: ReferenceAttachment, url: URL, data: Data) {
        guard let record = try active(repository).first(where: { $0.id == recordID }), let attachment = record.attachments.first(where: { $0.id == attachmentID }) else { throw ReferenceFailure("This attachment is no longer available.") }
        let url = repository.attachmentURL(attachment), values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 200_000_000 else { throw ReferenceFailure("This PDF is unavailable or too large.") }
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        guard data.count <= 200_000_000, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == attachment.sha256 else { throw ReferenceFailure("The PDF changed. Attach a verified copy in Reference.") }
        try Task.checkCancellation()
        return (record, attachment, url, data)
    }
}
