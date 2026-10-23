import Foundation

/// A portable citation payload. Preparing one never changes the catalogue or manuscript.
enum ReferenceCitation {
    enum Format: String, CaseIterable { case latex, markdown }
    static func text(_ record: ReferenceRecord, format: Format) throws -> String {
        guard ReferenceBibTeX.validToken(record.citationKey) else { throw ReferenceFailure("Choose a valid citation key.") }
        return format == .latex ? "\\cite{\(record.citationKey)}" : "[@\(record.citationKey)]"
    }
    static func appending(_ record: ReferenceRecord, to source: String) throws -> String {
        let entry = try ReferenceExport.bibtex([record])
        let commentsOnly = source.components(separatedBy: .newlines).allSatisfy { line in let text = line.trimmingCharacters(in: .whitespaces); return text.isEmpty || text.hasPrefix("%") }
        let existing = commentsOnly ? [] : try ReferenceBibTeX.parse(source)
        if let match = existing.first(where: { $0.citationKey == record.citationKey }) {
            guard try ReferenceExport.bibtex([match]) == entry else { throw ReferenceFailure("This citation key already has different details. Existing entries were kept.") }
            return source
        }
        let result = source + (source.isEmpty || source.hasSuffix("\n\n") ? "" : source.hasSuffix("\n") ? "\n" : "\n\n") + entry
        guard result.utf8.count <= 4_000_000 else { throw ReferenceFailure("The bibliography is too large.") }
        return result
    }
}
