import Foundation

enum ReferenceCorrection {
    static func parse(_ output: String) throws -> ReferenceRecord {
        guard output.utf8.count <= 80_000 else { throw ReferenceFailure("The suggestion was too large. Nothing changed.") }
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let start = text.firstIndex(of: "\n"), text.hasSuffix("```") { text = String(text[text.index(after: start)..<text.index(text.endIndex, offsetBy: -3)]) }
        let records = try ReferenceBibTeX.parse(text)
        guard records.count == 1, records[0].fields["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw ReferenceFailure("Request a suggestion for one reference at a time.") }
        return records[0]
    }
}
