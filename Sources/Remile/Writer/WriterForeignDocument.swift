import AppKit

/// Keep the original package for bounded text edits. Rich edits need a Writer DOCX copy.
@MainActor struct WriterForeignDocument {
    let archive: WordArchive
    private let baseline: NSAttributedString
    init(archive: WordArchive, text: NSAttributedString) { self.archive = archive; baseline = NSAttributedString(attributedString: text) }
    private func paragraphs(_ text: NSAttributedString) -> [NSAttributedString] {
        let string = text.string as NSString
        var result: [NSAttributedString] = [], start = 0
        while start < string.length {
            let range = string.paragraphRange(for: NSRange(location: start, length: 0))
            var end = NSMaxRange(range)
            while end > range.location && [10, 13].contains(string.character(at: end - 1)) { end -= 1 }
            result.append(text.attributedSubstring(from: NSRange(location: range.location, length: end - range.location)))
            start = NSMaxRange(range)
        }
        return result
    }
    private func styles(_ text: NSAttributedString) -> [NSDictionary] {
        var result: [NSDictionary] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            let value = NSDictionary(dictionary: attributes)
            if result.last?.isEqual(value) != true { result.append(value) }
        }
        return result
    }
    func updating(_ model: WriterModel) throws -> Data? {
        guard model.objects.isEmpty, model.paper == PaperSize.a4.rawValue, !model.landscape, model.pageStyle == WriterPageStyle() else { return nil }
        var attachments = false
        model.storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: model.storage.length)) { value, _, _ in if value != nil { attachments = true } }
        guard !attachments else { return nil }
        let document = try WordXML.parse(archive.read("word/document.xml"))
        guard let body = document.child("body"), body.children.allSatisfy({ ["p", "sectPr"].contains($0.local) }) else { return nil }
        let nodes = body.children.filter { $0.local == "p" }, before = paragraphs(baseline), after = paragraphs(model.storage)
        guard nodes.count == before.count, nodes.count == after.count else { return nil }
        for index in nodes.indices {
            let old = before[index], new = after[index]
            guard styles(old).elementsEqual(styles(new), by: { $0.isEqual($1) }) else { return nil }
            if old.string == new.string { continue }
            let paragraph = nodes[index]
            guard paragraph.children.allSatisfy({ ["pPr", "r", "proofErr"].contains($0.local) }) else { return nil }
            let runs = paragraph.children.filter { $0.local == "r" }
            guard runs.allSatisfy({ $0.children.allSatisfy { ["rPr", "t"].contains($0.local) } }) else { return nil }
            let textRuns = runs.filter { !$0.descendants("t").isEmpty }
            let properties = Set(textRuns.map { $0.child("rPr")?.xml ?? "" })
            let leaves = textRuns.flatMap { $0.descendants("t") }
            guard properties.count <= 1, let first = leaves.first, leaves.map(\.text).joined() == old.string else { return nil }
            let replacement = WordXML.Node(first.name, attributes: first.attributes.merging(["xml:space": "preserve"]) { _, new in new })
            replacement.content = [.text(new.string)]
            for run in textRuns {
                run.content = run.content.map { part in
                    guard case .node(let node) = part, node.local == "t" else { return part }
                    return .node(node === first ? replacement : WordXML.Node(node.name, attributes: node.attributes))
                }
            }
        }
        return archive.replacing("word/document.xml", with: Data(document.xml.utf8))
    }
}
