import Foundation

/// The submission date belongs to the preprint. A revision is not a new publication year.
enum ReferenceArxiv {
    static func parse(_ data: Data, expectedID: String) throws -> ReferenceRecord {
        let reader = EntryReader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.entries.count == 1, let entry = reader.entries.first,
              ReferencePDFMetadata.arxivID(in: entry["id"] ?? "").map(base) == base(expectedID),
              (!expectedID.contains("v") || ReferencePDFMetadata.arxivID(in: entry["id"] ?? "") == expectedID),
              let title = entry["title"], !title.isEmpty,
              let published = entry["published"], published.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T"#, options: .regularExpression) != nil,
              !reader.authors.isEmpty else { throw ReferenceFailure("The archive record did not match this paper.") }
        var record = ReferenceRecord(); record.type = "misc"
        record.fields = ["title": title, "author": reader.authors.joined(separator: " and "), "year": String(published.prefix(4)), "date": String(published.prefix(10)), "eprint": expectedID, "archiveprefix": "arXiv", "entrysubtype": "preprint", "url": "https://arxiv.org/abs/" + expectedID]
        if let abstract = entry["summary"], !abstract.isEmpty { record.fields["abstract"] = abstract }
        return record
    }
    static func base(_ id: String) -> String { id.replacingOccurrences(of: #"v[0-9]+$"#, with: "", options: .regularExpression) }
    private final class EntryReader: NSObject, XMLParserDelegate {
        var entries: [[String: String]] = [], authors: [String] = []
        private var entry: [String: String]?, stack: [String] = [], value = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            stack.append(name); value = ""
            if name == "entry" { entry = [:] }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if name == "entry", let entry { entries.append(entry); self.entry = nil }
            else if entry != nil {
                if name == "name", stack.dropLast().last == "author", !text.isEmpty { authors.append(text) }
                else if stack.dropLast().last == "entry", ["id", "title", "published", "summary"].contains(name) { entry?[name] = text }
            }
            _ = stack.popLast(); value = ""
        }
    }
}

actor ReferenceArchivePacing {
    static let shared = ReferenceArchivePacing()
    private var next = ContinuousClock.now
    func wait() async throws {
        let slot = max(next, .now); next = slot.advanced(by: .seconds(3))
        try await Task.sleep(until: slot, clock: .continuous)
    }
}
