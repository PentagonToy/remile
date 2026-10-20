import AppKit

/// A private TextKit stack per conversion keeps tables and image attachments in layout.
enum WordPDF {
    static func write(_ input: URL, to output: URL, progress: (Double) -> Void) async throws {
        let fileSize = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0, fileSize <= 64 * 1024 * 1024 else { throw WordArchive.Failure.limit }
        let type: NSAttributedString.DocumentType = input.pathExtension.lowercased() == "docx" ? .officeOpenXML : .docFormat
        var attributes: NSDictionary?
        let imported: NSAttributedString
        var furniture: WordFurniture?
        if input.pathExtension.lowercased() == "docx" {
            let archive = try WordArchive(Data(contentsOf: input)), document = try WordXML.parse(archive.read("word/document.xml"))
            furniture = try await WordFurniture.load(archive, document: document)
            for section in document.descendants("sectPr") { section.content.removeAll { if case .node(let node) = $0 { return ["headerReference", "footerReference"].contains(node.local) }; return false } }
            imported = try await WordImages.load(archive, part: "word/document.xml", sourceXML: Data(document.xml.utf8), attributes: &attributes)
        } else { imported = try NSAttributedString(url: input, options: [.documentType: type], documentAttributes: &attributes) }
        let content = NSMutableAttributedString(attributedString: imported)
        guard content.length > 0 else { throw DocumentConverter.Failure.empty }
        let metadata = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        let paper = (metadata[.paperSize] as? NSValue)?.sizeValue ?? NSSize(width: 612, height: 792)
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat { (metadata[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 44 }
        let left = margin(.leftMargin), right = margin(.rightMargin), top = margin(.topMargin), bottom = margin(.bottomMargin)
        let available = NSSize(width: paper.width - left - right, height: paper.height - top - bottom)
        guard paper.width.isFinite, paper.height.isFinite, paper.width >= 72, paper.height >= 72, paper.width <= 2880, paper.height <= 2880,
              [left, right, top, bottom].allSatisfy({ $0.isFinite && $0 >= 0 }), available.width >= 36, available.height >= 36 else { throw DocumentConverter.Failure.pageLimit }
        var invalidAttachment = false
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { if value != nil { invalidAttachment = true }; return }
            let source = (attachment.attachmentCell as? NSTextAttachmentCell)?.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
            guard let source, source.size.width > 0, source.size.height > 0, let image = source.copy() as? NSImage else { invalidAttachment = true; return }
            let scale = min(1, available.width / image.size.width, max(1, available.height - 24) / image.size.height)
            image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let replacement = NSTextAttachment()
            replacement.attachmentCell = NSTextAttachmentCell(imageCell: image)
            content.addAttribute(.attachment, value: replacement, range: range)
        }
        guard !invalidAttachment else { throw DocumentConverter.Failure.attachments }
        // Supply black only where the importer omitted a text colour.
        content.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if value == nil { content.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        try paginate(content, paper: paper, origin: NSPoint(x: left, y: top), available: available, to: output, furniture: furniture, progress: progress)
    }

    static func paginate(_ content: NSAttributedString, paper: NSSize, origin: NSPoint, available: NSSize, to output: URL, furniture: WordFurniture? = nil, progress: (Double) -> Void) throws {
        guard !content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentConverter.Failure.empty }
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        layout.backgroundLayoutEnabled = false
        storage.addLayoutManager(layout)
        var media = CGRect(origin: .zero, size: paper)
        guard let context = CGContext(output as CFURL, mediaBox: &media, nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { context.closePDF() }
        var links: [(URL, NSRange)] = []
        content.enumerateAttribute(.link, in: NSRange(location: 0, length: content.length)) { value, characters, _ in
            guard let value, let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            links.append((url, layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)))
        }
        var end = 0, pages = 0
        var containers: [(NSTextContainer, NSRange)] = []
        while end < layout.numberOfGlyphs {
            try Task.checkCancellation()
            guard pages < 1000 else { throw DocumentConverter.Failure.pageLimit }
            let container = NSTextContainer(containerSize: available)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let range = layout.glyphRange(for: container)
            guard range.length > 0, NSMaxRange(range) > end else { throw DocumentConverter.Failure.pageLimit }
            containers.append((container, range))
            end = NSMaxRange(range); pages += 1
            progress(0.5 * Double(end) / Double(max(1, layout.numberOfGlyphs)))
        }
        for (index, entry) in containers.enumerated() {
            try Task.checkCancellation()
            let (container, range) = entry
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(media)
            context.saveGState()
            context.translateBy(x: origin.x, y: paper.height - origin.y)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: .zero)
            layout.drawGlyphs(forGlyphRange: range, at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            for (url, linkRange) in links {
                let glyphs = NSIntersectionRange(linkRange, range)
                guard glyphs.length > 0 else { continue }
                layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, _ in
                    let part = NSIntersectionRange(glyphs, line)
                    guard part.length > 0 else { return }
                    let box = layout.boundingRect(forGlyphRange: part, in: container)
                    let rectangle = CGRect(x: origin.x + box.minX, y: paper.height - origin.y - box.maxY, width: box.width, height: box.height)
                    context.setURL(url as CFURL, for: rectangle)
                }
            }
            try furniture?.draw(page: index, count: containers.count, paper: paper, origin: origin, available: available, context: context)
            context.endPDFPage()
            progress(0.5 + 0.5 * Double(index + 1) / Double(containers.count))
        }
    }
}
