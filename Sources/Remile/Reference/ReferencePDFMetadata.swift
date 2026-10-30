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
            let journal = journalHeader(in: text)
            if let title = fields["title"], placeholderTitle(title, journal: journal) { fields.removeValue(forKey: "title") }
            let expression = try! NSRegularExpression(pattern: #"10\.[0-9]{4,9}/[-._;()/:A-Z0-9]+"#, options: [.caseInsensitive])
            let values = Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
                guard let range = Range(match.range, in: text) else { return nil }
                var value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                while value.hasSuffix(")"), value.filter({ $0 == ")" }).count > value.filter({ $0 == "(" }).count { value.removeLast() }
                return value.lowercased()
            })
            if values.count == 1 { fields["doi"] = values.first }
            if let id = arxivID(in: text) { fields["eprint"] = id; fields["archiveprefix"] = "arXiv"; fields["url"] = "https://arxiv.org/abs/" + id; fields["entrysubtype"] = "preprint" }
            if fields["title"] == nil, let title = prominentTitle(page, journal: journal) { fields["title"] = title }
        }
        var cover = ""
        for index in 0..<min(3, pdf.pageCount) {
            if let text = pdf.page(at: index)?.string { cover += String(text.prefix(6000)) + "\n" }
        }
        if let kind = degree(in: cover) { fields["type"] = kind == .mastersThesis ? "Master's thesis" : "PhD dissertation" }
        if fields["title"] == nil { fields["title"] = fallback.lowercased().hasSuffix(".pdf") ? String(fallback.dropLast(4)) : fallback }
        return fields
    }
    static func arxivID(in text: String) -> String? {
        let pattern = #"(?:arxiv\s*:\s*|arxiv\.org/(?:abs|pdf)/)([0-9]{4}\.[0-9]{4,5}(?:v[0-9]+)?|[a-z-]+(?:\.[A-Z]{2})?/[0-9]{7}(?:v[0-9]+)?)"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive), ns = String(text.prefix(40000)) as NSString
        let ids = regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        let bases = Set(ids.map { $0.replacingOccurrences(of: #"v[0-9]+$"#, with: "", options: .regularExpression) })
        return bases.count == 1 ? ids.first : nil
    }
    static func placeholderTitle(_ text: String, journal: String? = nil) -> Bool {
        if !useful(text) { return true }
        guard let journal else { return false }
        let title = compact(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let publication = compact(journal).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return !publication.isEmpty && title == publication
    }
    static func degree(in text: String) -> ReferenceKind? {
        var cover = String(text.prefix(18_000))
        if let body = cover.range(of: #"(?im)^\s*(?:abstract|introduction|references)\s*$"#, options: .regularExpression) {
            cover = String(cover[..<body.lowerBound])
        }
        let context = #"(?:(?:thesis|dissertation)[\s\S]{0,80}(?:submitted|presented)|to\s+obtain\s+(?:the\s+)?degree|fulfil+ment\s+of)[\s\S]{0,180}"#
        let doctorate = cover.range(of: context + #"(?:doctor of philosophy|doctoral (?:thesis|dissertation)|ph\.?\s*d\.?)"#, options: [.regularExpression, .caseInsensitive]) != nil
        let masters = cover.range(of: context + #"master(?:['’]?s)?\s+(?:of\s+(?:science|arts|engineering)|thesis)"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard doctorate != masters else { return nil }
        return doctorate ? .doctoralThesis : .mastersThesis
    }
    private static func journalHeader(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).prefix(30).map(compact).filter { !$0.isEmpty }
        guard let index = lines.firstIndex(where: { $0.lowercased().contains("journal homepage") }), index > 0 else { return nil }
        let header = lines[index - 1]
        return header.count >= 6 && header.count <= 120 ? header : nil
    }
    private static func compact(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func useful(_ value: String) -> Bool {
        let value = compact(value)
        // Publisher production IDs are not bibliographic titles.
        if value.range(of: #"^[A-Z]{2,12}[_-][0-9]{5,}[0-9 ._-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return !value.lowercased().hasPrefix("arxiv:") && !value.lowercased().hasPrefix("arxiv ") && !value.lowercased().contains("arxiv.org/") && !value.isEmpty && value.count < 600 && !["untitled", "untitled reference", "unknown", "author", "title", "user"].contains(value.lowercased()) && !value.lowercased().hasPrefix("microsoft word") && !value.lowercased().hasSuffix(".pdf") && !value.lowercased().hasSuffix(".docx")
    }
    private static func prominentTitle(_ page: PDFPage, journal: String?) -> String? {
        guard let attributed = page.attributedString, attributed.length <= 200_000 else { return nil }
        let text = attributed.string as NSString
        var lines: [(text: String, size: CGFloat)] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { value, range, _, stop in
            guard lines.count < 70 else { stop.pointee = true; return }
            let value = compact(value ?? "")
            if value.lowercased().hasPrefix("abstract") { stop.pointee = true; return }
            guard !value.isEmpty, !placeholderTitle(value, journal: journal),
                !value.lowercased().contains("contents lists available"),
                !value.lowercased().contains("journal homepage") else { return }
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
