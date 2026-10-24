import AppKit
import PDFKit

/// Local PDF evidence only. Missing bibliographic facts are left for review.
enum ReferencePDFMetadata {
    static func fields(_ pdf: PDFDocument, fallback: String) -> [String: String] {
        var fields: [String: String] = [:]
        let attributes = pdf.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String, useful(title) { fields["title"] = compact(title) }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, useful(author) { fields["author"] = compact(author) }
        if let page = pdf.page(at: 0) {
            let text = String((page.string ?? "").prefix(40_000))
            let expression = try! NSRegularExpression(pattern: #"10\.[0-9]{4,9}/[-._;()/:A-Z0-9]+"#, options: [.caseInsensitive])
            let values = Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
                guard let range = Range(match.range, in: text) else { return nil }
                var value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                while value.hasSuffix(")"), value.filter({ $0 == ")" }).count > value.filter({ $0 == "(" }).count { value.removeLast() }
                return value.lowercased()
            })
            if values.count == 1 { fields["doi"] = values.first }
            if let id = arxivID(in: text) { fields["eprint"] = id; fields["archiveprefix"] = "arXiv"; fields["url"] = "https://arxiv.org/abs/" + id; fields["entrysubtype"] = "preprint" }
            if fields["title"] == nil, let title = prominentTitle(page) { fields["title"] = title }
        }
        if fields["title"] == nil { fields["title"] = fallback }
        return fields
    }
    static func arxivID(in text: String) -> String? {
        let pattern = #"(?:arxiv\s*:\s*|arxiv\.org/(?:abs|pdf)/)([0-9]{4}\.[0-9]{4,5}(?:v[0-9]+)?|[a-z-]+(?:\.[A-Z]{2})?/[0-9]{7}(?:v[0-9]+)?)"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive), ns = String(text.prefix(40000)) as NSString
        let ids = regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        let bases = Set(ids.map { $0.replacingOccurrences(of: #"v[0-9]+$"#, with: "", options: .regularExpression) })
        return bases.count == 1 ? ids.first : nil
    }
    static func placeholderTitle(_ text: String) -> Bool { !useful(text) }
    private static func compact(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func useful(_ value: String) -> Bool {
        let value = compact(value)
        return !value.lowercased().hasPrefix("arxiv:") && !value.lowercased().hasPrefix("arxiv ") && !value.lowercased().contains("arxiv.org/") && !value.isEmpty && value.count < 600 && !["untitled", "untitled reference", "unknown", "author", "title", "user"].contains(value.lowercased()) && !value.lowercased().hasPrefix("microsoft word") && !value.lowercased().hasSuffix(".pdf") && !value.lowercased().hasSuffix(".docx")
    }
    private static func prominentTitle(_ page: PDFPage) -> String? {
        guard let attributed = page.attributedString, attributed.length <= 200_000 else { return nil }
        let text = attributed.string as NSString
        var lines: [(text: String, size: CGFloat)] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { value, range, _, stop in
            guard lines.count < 70 else { stop.pointee = true; return }
            let value = compact(value ?? "")
            if value.lowercased().hasPrefix("abstract") { stop.pointee = true; return }
            guard !value.isEmpty else { return }
            var size: CGFloat = 0
            attributed.enumerateAttribute(.font, in: range) { font, _, _ in size = max(size, (font as? NSFont)?.pointSize ?? 0) }
            lines.append((value, size))
        }
        let candidates = lines.indices.filter { lines[$0].text.count >= 8 && lines[$0].size >= 13 && lines[$0].size <= 32 && !lines[$0].text.lowercased().contains("doi") && !lines[$0].text.contains("@") && useful(lines[$0].text) }
        guard let first = candidates.max(by: { lines[$0].size < lines[$1].size }) else { return nil }
        let size = lines[first].size
        var start = first, end = first
        while start > 0, abs(lines[start - 1].size - size) < 0.6 { start -= 1 }
        while end + 1 < lines.count, abs(lines[end + 1].size - size) < 0.6 { end += 1 }
        let title = lines[start...end].map(\.text).joined(separator: " ")
        guard title.count >= 20, title.count <= 350, end - start < 5, useful(title), !title.lowercased().contains("all rights reserved") else { return nil }
        // A competing equally prominent block is too ambiguous to assign as a title.
        guard !lines.indices.contains(where: { ($0 < start || $0 > end) && abs(lines[$0].size - size) < 0.6 && lines[$0].text.count >= 20 && useful(lines[$0].text) }) else { return nil }
        return title
    }
}
