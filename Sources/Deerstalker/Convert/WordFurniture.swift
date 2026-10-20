import AppKit

struct WordFurniture {
    static let pageToken = "DEERSTALKER_PAGE_FIELD_7D9B"
    static let countToken = "DEERSTALKER_PAGES_FIELD_7D9B"
    var headers: [String: NSAttributedString] = [:]
    var footers: [String: NSAttributedString] = [:]
    var first = false
    var even = false
    var start = 1
    var headerDistance: CGFloat = 36
    var footerDistance: CGFloat = 36
    static func load(_ archive: WordArchive, document: WordXML.Node) async throws -> WordFurniture {
        var result = WordFurniture()
        guard let section = document.descendants("sectPr").last else { return result }
        func enabled(_ node: WordXML.Node?) -> Bool { guard let node else { return false }; return !["0", "false", "off"].contains(node.attribute("val") ?? "1") }
        result.first = enabled(section.child("titlePg"))
        if archive.entries.contains(where: { $0.name == "word/settings.xml" }) { result.even = enabled(try WordXML.parse(archive.read("word/settings.xml")).child("evenAndOddHeaders")) }
        if let numbering = section.child("pgNumType") {
            guard numbering.attribute("fmt") == nil || numbering.attribute("fmt") == "decimal" else { throw WordImages.Failure.feature("This page-number format is not supported yet.") }
            if let start = numbering.attribute("start") { guard let number = Int(start), number >= 0, number < 1_000_000 else { throw WordImages.Failure.unsupported }; result.start = number }
        }
        if let margins = section.child("pgMar") {
            if let value = margins.attribute("header").flatMap(Double.init) { result.headerDistance = value / 20 }
            if let value = margins.attribute("footer").flatMap(Double.init) { result.footerDistance = value / 20 }
        }
        guard result.headerDistance.isFinite, result.footerDistance.isFinite, result.headerDistance >= 0, result.footerDistance >= 0 else { throw WordImages.Failure.unsupported }
        let references = section.children.filter { ["headerReference", "footerReference"].contains($0.local) }
        guard references.count <= 6 else { throw WordImages.Failure.unsupported }
        if references.isEmpty { return result }
        let relationships = try WordXML.parse(archive.read("word/_rels/document.xml.rels"))
        for reference in references {
            try Task.checkCancellation()
            let kind = reference.local == "headerReference" ? "header" : "footer"
            guard let id = reference.attribute("id"), let relation = relationships.children.first(where: { $0.attribute("Id") == id }), relation.attribute("TargetMode") != "External",
                  relation.attribute("Type")?.hasSuffix("/" + kind) == true, let target = relation.attribute("Target"), !target.contains(":"), !target.contains("%"), !target.contains("\\") else { throw WordImages.Failure.unsupported }
            var components = target.hasPrefix("/") ? [] : ["word"]
            for value in target.split(separator: "/") { if value == ".." { guard !components.isEmpty else { throw WordImages.Failure.unsupported }; components.removeLast() } else if value != "." { components.append(String(value)) } }
            let part = components.joined(separator: "/")
            let root = try WordXML.parse(archive.read(part))
            try fields(root)
            var attributes: NSDictionary?
            let text = try await WordImages.load(archive, part: part, sourceXML: Data(root.xml.utf8), attributes: &attributes)
            let type = reference.attribute("type") ?? "default"
            guard ["default", "first", "even"].contains(type) else { throw WordImages.Failure.unsupported }
            if kind == "header" { guard result.headers[type] == nil else { throw WordImages.Failure.unsupported }; result.headers[type] = text }
            else { guard result.footers[type] == nil else { throw WordImages.Failure.unsupported }; result.footers[type] = text }
        }
        return result
    }
    private static func fieldToken(_ instruction: String) throws -> String {
        let words = instruction.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = words.first?.uppercased(), ["PAGE", "NUMPAGES"].contains(name), words.count == 1 || words.dropFirst() == ["\\*", "MERGEFORMAT"] else { throw WordImages.Failure.feature("This Word field is not supported yet.") }
        return name == "PAGE" ? pageToken : countToken
    }
    private static func run(_ token: String, style: WordXML.Node? = nil) -> WordXML.Node {
        let run = WordXML.Node("w:r", attributes: ["xmlns:w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"])
        if let style { run.content.append(.node(style)) }
        let text = WordXML.Node("w:t"); text.content = [.text(token)]; run.content.append(.node(text)); return run
    }
    private static func fields(_ node: WordXML.Node) throws {
        var output: [WordXML.Node.Content] = [], index = 0
        while index < node.content.count {
            let item = node.content[index]
            guard case .node(let child) = item else { output.append(item); index += 1; continue }
            if child.local == "fldSimple" {
                output.append(.node(run(try fieldToken(child.attribute("instr") ?? ""), style: child.children.first?.child("rPr"))))
            } else if child.local == "r", child.descendants("fldChar").contains(where: { $0.attribute("fldCharType") == "begin" }) {
                var instruction = "", end: Int?, depth = 0
                for position in index..<node.content.count {
                    guard case .node(let element) = node.content[position] else { continue }
                    for marker in element.descendants("fldChar") { if marker.attribute("fldCharType") == "begin" { depth += 1 }; if marker.attribute("fldCharType") == "end" { depth -= 1 } }
                    instruction += element.descendants("instrText").map(\.text).joined()
                    if depth == 0 { end = position; break }
                }
                guard let end else { throw WordImages.Failure.unsupported }
                output.append(.node(run(try fieldToken(instruction), style: child.child("rPr")))); index = end
            } else { try fields(child); output.append(.node(child)) }
            index += 1
        }
        node.content = output
    }
    func draw(page: Int, count: Int, paper: NSSize, origin: NSPoint, available: NSSize, context: CGContext) throws {
        let number = start + page
        let type = first && page == 0 ? "first" : even && number % 2 == 0 ? "even" : "default"
        for (header, dictionary) in [(true, headers), (false, footers)] {
            guard let source = dictionary[type], source.length > 0 else { continue }
            let text = NSMutableAttributedString(attributedString: source)
            for (token, value) in [(Self.pageToken, String(number)), (Self.countToken, String(count))] {
                while true { let range = (text.string as NSString).range(of: token); if range.location == NSNotFound { break }; text.replaceCharacters(in: range, with: value) }
            }
            let capacity = header ? origin.y - headerDistance - 3 : paper.height - origin.y - available.height - footerDistance - 3
            guard capacity > 0 else { throw WordImages.Failure.feature("The Word header or footer overlaps the page body.") }
            let storage = NSTextStorage(attributedString: text), layout = NSLayoutManager(), container = NSTextContainer(containerSize: NSSize(width: available.width, height: capacity))
            layout.backgroundLayoutEnabled = false; container.lineFragmentPadding = 0; storage.addLayoutManager(layout); layout.addTextContainer(container); layout.ensureLayout(for: container)
            let range = layout.glyphRange(for: container)
            guard NSMaxRange(range) == layout.numberOfGlyphs else { throw WordImages.Failure.feature("The Word header or footer does not fit its margin.") }
            let used = layout.usedRect(for: container)
            let y = header ? headerDistance : paper.height - footerDistance - used.maxY
            context.saveGState(); context.translateBy(x: origin.x, y: paper.height - y); context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: .zero); layout.drawGlyphs(forGlyphRange: range, at: .zero)
            NSGraphicsContext.restoreGraphicsState(); context.restoreGState()
        }
    }
}
