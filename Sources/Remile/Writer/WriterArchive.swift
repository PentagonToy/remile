import AppKit
import CryptoKit
import zlib

/// A readable DOCX plus a verified editing snapshot. External edits invalidate the snapshot.
@MainActor enum WriterArchive {
    private struct Formula: Codable { var location: Int; var source: String }
    private struct Snapshot: Codable {
        var schema = 1
        var fingerprint: String
        var text: Data
        var paper: String
        var landscape: Bool
        var objects: [WriterObject]
        var formulae: [Formula]
        var pageStyle: WriterPageStyle?
    }
    static func fingerprint(_ parts: [String: Data]) -> String {
        var hash = SHA256()
        for key in parts.keys.sorted() where key != "remile/writer.json" { hash.update(data: Data(key.utf8)); hash.update(data: Data([0])); hash.update(data: parts[key]!) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func encode(_ model: WriterModel) throws -> Data {
        guard model.storage.length <= 200_000, model.objects.count <= 100 else { throw ReferenceFailure("This document is too large for Writer.") }
        guard let canvas = model.canvas else { throw ReferenceFailure("Open the Writer canvas before exporting.") }
        let ranges = canvas.ranges()
        var parts: [String: Data] = [:], relationships = "", media = 0
        func image(_ attachment: NSTextAttachment) throws -> String {
            guard let image = attachment.image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw ReferenceFailure("An equation image could not be saved.") }
            media += 1; let id = "image\(media)"
            parts["word/media/\(id).png"] = png
            relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(id).png\"/>"
            let width = attachment.bounds.width > 0 ? attachment.bounds.width : image.size.width, height = attachment.bounds.height > 0 ? attachment.bounds.height : image.size.height
            return "<w:r><w:pict><v:shape id=\"\(id)\" type=\"#_x0000_t75\" style=\"width:\(width)pt;height:\(height)pt\"><v:imagedata r:id=\"\(id)\"/></v:shape></w:pict></w:r>"
        }
        func run(_ text: String, attrs: [NSAttributedString.Key: Any]) throws -> String {
            if let attachment = attrs[.attachment] as? NSTextAttachment { return try image(attachment) }
            let font = attrs[.font] as? NSFont ?? model.font.font(size: 12), traits = NSFontManager.shared.traits(of: font)
            let colour = WriterPalette.hex(attrs[.foregroundColor] as? NSColor ?? .black)
            let name = escape(font.familyName ?? "Times New Roman")
            let properties = "<w:rFonts w:ascii=\"\(name)\" w:hAnsi=\"\(name)\"/><w:sz w:val=\"\(Int(font.pointSize * 2))\"/><w:color w:val=\"\(String(format: "%06X", colour))\"/>" + (traits.contains(.boldFontMask) ? "<w:b/>" : "") + (traits.contains(.italicFontMask) ? "<w:i/>" : "")
            let content = escape(text).replacingOccurrences(of: "\t", with: "</w:t><w:tab/><w:t xml:space=\"preserve\">")
            return "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(content)</w:t></w:r>"
        }
        var body = ""
        for (page, range) in ranges.enumerated() {
            let pageText = model.storage.attributedSubstring(from: range), string = pageText.string as NSString
            var start = 0, first = true
            repeat {
                let paragraphRange = string.length == 0 ? NSRange(location: 0, length: 0) : string.paragraphRange(for: NSRange(location: start, length: 0))
                var end = NSMaxRange(paragraphRange)
                while end > paragraphRange.location && [10, 13].contains(string.character(at: end - 1)) { end -= 1 }
                let textRange = NSRange(location: paragraphRange.location, length: end - paragraphRange.location)
                let attrs = string.length > 0 ? pageText.attributes(at: paragraphRange.location, effectiveRange: nil) : model.attributes
                let style = attrs[.paragraphStyle] as? NSParagraphStyle ?? .default
                let alignment = justification(style.alignment.rawValue)
                let before = first && page > 0 ? "<w:pageBreakBefore/>" : ""
                body += "<w:p><w:pPr>\(before)<w:jc w:val=\"\(alignment)\"/><w:spacing w:line=\"\(Int(max(1, style.lineHeightMultiple) * 240))\" w:lineRule=\"auto\"/></w:pPr>"
                if first {
                    for object in model.objects where object.page == page {
                        var imageID: String?
                        if let data = object.imageData, object.kind == .image {
                            media += 1; let id = "image\(media)"; imageID = id
                            parts["word/media/\(id).png"] = data
                            relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(id).png\"/>"
                        }
                        body += shape(object, imageID: imageID)
                    }
                }
                var failure: Error?
                pageText.enumerateAttributes(in: textRange) { attrs, range, _ in
                    do { body += try run(string.substring(with: range), attrs: attrs) } catch { failure = error }
                }
                if let failure { throw failure }
                body += "</w:p>"; first = false; start = NSMaxRange(paragraphRange)
            } while start < string.length
        }
        var pageReferences = ""
        var pageTypes = ""
        let decoration = model.pageStyle
        func pagePart(_ header: Bool) {
            let text = header ? decoration.header : decoration.footer
            let rule = header ? decoration.topLine : decoration.bottomLine
            let numbered = !header && decoration.pageNumbers
            guard !text.isEmpty || rule || numbered else { return }
            let tag = header ? "hdr" : "ftr", name = header ? "header1.xml" : "footer1.xml", id = header ? "pageHeader" : "pageFooter"
            let partType = header ? "header" : "footer", border = header ? "bottom" : "top"
            let line = rule ? "<w:pBdr><w:\(border) w:val=\"single\" w:sz=\"4\" w:color=\"000000\"/></w:pBdr>" : ""
            let label = text + (numbered && !text.isEmpty ? " · " : "")
            let page = numbered ? "<w:fldSimple w:instr=\"PAGE\"/>" : ""
            parts["word/" + name] = Data("<w:\(tag) xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:pPr><w:jc w:val=\"center\"/>\(line)<w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\"/><w:sz w:val=\"20\"/></w:rPr><w:t xml:space=\"preserve\">\(escape(label))</w:t></w:r>\(page)</w:p></w:\(tag)>".utf8)
            relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(partType)\" Target=\"\(name)\"/>"
            pageReferences += "<w:\(partType)Reference w:type=\"default\" r:id=\"\(id)\"/>"
            pageTypes += "<Override PartName=\"/word/\(name)\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.\(partType)+xml\"/>"
        }
        pagePart(true); pagePart(false)
        let size = model.pageSize
        body += "<w:sectPr>\(pageReferences)<w:pgSz w:w=\"\(Int(size.width * 20))\" w:h=\"\(Int(size.height * 20))\"/><w:pgMar w:top=\"1120\" w:right=\"1120\" w:bottom=\"1120\" w:left=\"1120\" w:header=\"440\" w:footer=\"440\"/><w:cols w:num=\"\(decoration.columnCount)\" w:space=\"400\"/></w:sectPr>"
        parts["word/document.xml"] = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:w10=\"urn:schemas-microsoft-com:office:word\" xmlns:o=\"urn:schemas-microsoft-com:office:office\"><w:body>" + body + "</w:body></w:document>").utf8)
        parts["word/_rels/document.xml.rels"] = Data(("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + relationships + "</Relationships>").utf8)
        parts["_rels/.rels"] = Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"document\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8)
        parts["[Content_Types].xml"] = Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"json\" ContentType=\"application/json\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>\(pageTypes)</Types>".utf8)
        var formulae: [Formula] = []
        model.storage.enumerateAttribute(.init("remile.formula"), in: NSRange(location: 0, length: model.storage.length)) { value, range, _ in if let source = value as? String { formulae.append(Formula(location: range.location, source: source)) } }
        let text = try model.storage.data(from: NSRange(location: 0, length: model.storage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        parts["remile/writer.json"] = try JSONEncoder().encode(Snapshot(fingerprint: fingerprint(parts), text: text, paper: model.paper, landscape: model.landscape, objects: model.objects, formulae: formulae, pageStyle: model.pageStyle))
        return try zip(parts)
    }
    private static func escape(_ text: String) -> String {
        let value = String(String.UnicodeScalarView(text.unicodeScalars.filter { [9, 10, 13].contains($0.value) || (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || $0.value >= 0x10000 }))
        return MathMarkup.escape(value)
    }
    private static func justification(_ value: Int) -> String {
        switch NSTextAlignment(rawValue: value) { case .center: return "center"; case .right: return "right"; case .justified: return "both"; default: return "left" }
    }
    private static func shape(_ item: WriterObject, imageID: String? = nil) -> String {
        let emphasis = (item.bold == true ? "<w:b/>" : "") + (item.italic == true ? "<w:i/>" : "")
        let wrap = item.wrapsText == true ? "<w10:wrap type=\"square\" side=\"both\"/>" : "<w10:wrap type=\"none\"/>"
        let lock = item.locked == true ? "<o:lock v:ext=\"edit\" position=\"t\"/>" : ""
        let fill = String(format: "#%06X", item.fillHex ?? item.hex)
        let opacity = Int((item.fillOpacity ?? 0.12) * 100)
        let rect = item.bounds, colour = String(format: "#%06X", item.hex)
        let style = "position:absolute;margin-left:\(rect.minX)pt;margin-top:\(rect.minY)pt;width:\(rect.width)pt;height:\(rect.height)pt;mso-position-horizontal-relative:page;mso-position-vertical-relative:page;z-index:1"
        let attributes = "id=\"shape\(item.id.uuidString)\" style=\"\(style)\" strokecolor=\"\(colour)\" strokeweight=\"\(item.width)pt\" filled=\"\(item.filled ? "t" : "f")\" fillcolor=\"\(fill)\""
        if item.kind == .image, let imageID { return "<w:r><w:pict><v:shape \(attributes) type=\"#_x0000_t75\">\(wrap)\(lock)<v:imagedata r:id=\"\(imageID)\"/></v:shape></w:pict></w:r>" }
        if item.kind == .table {
            let border = "w:val=\"single\" w:sz=\"\(Int(item.width * 8))\" w:color=\"\(colour.dropFirst())\""
            let borders = ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) \(border)/>" }.joined()
            let width = Int(rect.width * 20 / Double(item.columns)), height = Int(rect.height * 20 / Double(item.rows))
            var table = "<w:tbl><w:tblPr><w:tblLayout w:type=\"fixed\"/><w:tblBorders>\(borders)</w:tblBorders></w:tblPr><w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: item.columns) + "</w:tblGrid>"
            for row in 0..<item.rows {
                table += "<w:tr><w:trPr><w:trHeight w:val=\"\(height)\" w:hRule=\"atLeast\"/></w:trPr>"
                for column in 0..<item.columns {
                    let text = escape(item.cells[row * item.columns + column]).replacingOccurrences(of: "\n", with: "</w:t><w:br/><w:t xml:space=\"preserve\">")
                    table += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr><w:p><w:pPr><w:jc w:val=\"\(justification(item.alignment))\"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii=\"\(escape(item.font))\" w:hAnsi=\"\(escape(item.font))\"/><w:sz w:val=\"\(Int(item.fontSize * 2))\"/>\(emphasis)</w:rPr><w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p></w:tc>"
                }
                table += "</w:tr>"
            }
            table += "</w:tbl><w:p/>"
            return "<w:r><w:pict><v:rect \(attributes) stroked=\"f\">\(wrap)\(lock)<v:textbox inset=\"0,0,0,0\"><w:txbxContent>\(table)</w:txbxContent></v:textbox></v:rect></w:pict></w:r>"
        }
        if item.kind == .line {
            func arrow(_ value: WriterObject.Arrow) -> String { value == .none ? "none" : value == .open ? "open" : "block" }
            return "<w:r><w:pict><v:line \(attributes) from=\"\(item.start.x - rect.minX),\(item.start.y - rect.minY)\" to=\"\(item.end.x - rect.minX),\(item.end.y - rect.minY)\">\(wrap)\(lock)<v:stroke startarrow=\"\(arrow(item.startArrow))\" endarrow=\"\(arrow(item.endArrow))\"/></v:line></w:pict></w:r>"
        }
        let font = escape(item.font), text = escape(item.text).replacingOccurrences(of: "\n", with: "</w:t><w:br/><w:t xml:space=\"preserve\">")
        let justification = justification(item.alignment)
        return "<w:r><w:pict><v:rect \(attributes)>\(wrap)\(lock)<v:fill opacity=\"\(opacity)%\"/><v:textbox inset=\"8pt,6pt,8pt,6pt\"><w:txbxContent><w:p><w:pPr><w:jc w:val=\"\(justification)\"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii=\"\(font)\" w:hAnsi=\"\(font)\"/><w:sz w:val=\"\(Int(item.fontSize * 2))\"/>\(emphasis)<w:color w:val=\"\(String(colour.dropFirst()))\"/></w:rPr><w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p></w:txbxContent></v:textbox></v:rect></w:pict></w:r>"
    }
    @discardableResult static func open(_ url: URL, model: WriterModel) throws -> Bool {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32_000_000 else { throw ReferenceFailure("Use a DOCX smaller than 32 MB.") }
        let data = try Data(contentsOf: url), archive = try WordArchive(data)
        if archive.entries.contains(where: { $0.name == "remile/writer.json" }) {
            let saved = try JSONDecoder().decode(Snapshot.self, from: archive.read("remile/writer.json"))
            let parts = try Dictionary(uniqueKeysWithValues: archive.entries.filter { $0.name != "remile/writer.json" }.map { ($0.name, try archive.read($0.name)) })
            guard saved.schema == 1, saved.fingerprint == fingerprint(parts) else { throw ReferenceFailure("This DOCX was changed outside Writer. Its saved editing state cannot be reused.") }
            guard let paper = PaperSize(rawValue: saved.paper), saved.objects.count <= 100, saved.formulae.count <= 100, saved.text.count <= 25_000_000 else { throw ReferenceFailure("Unsupported Writer document.") }
            guard saved.objects.compactMap(\.imageData).reduce(0, { $0 + $1.count }) <= 10_000_000,
                  saved.objects.filter({ $0.kind == .image }).count <= 20,
                  saved.objects.allSatisfy({ $0.kind != .image || $0.imageData.map(WriterImage.valid) == true }) else { throw ReferenceFailure("Invalid image data.") }
            let pageStyle = saved.pageStyle ?? WriterPageStyle()
            guard pageStyle.valid else { throw ReferenceFailure("Invalid page settings.") }
            let page = paper.points(landscape: saved.landscape)
            guard saved.objects.allSatisfy({ $0.page >= 0 && $0.page < 40 && [$0.start.x, $0.start.y, $0.end.x, $0.end.y, $0.width, $0.fontSize].allSatisfy(\.isFinite) && $0.bounds.maxX <= page.width && $0.bounds.maxY <= page.height && $0.bounds.minX >= 0 && $0.bounds.minY >= 0 && (0.5...12).contains($0.width) && (6...72).contains($0.fontSize) && $0.text.count <= 10_000 && ($0.fillOpacity == nil || ($0.fillOpacity!.isFinite && (0...1).contains($0.fillOpacity!))) && ($0.fillHex ?? 0) <= 0xFFFFFF && (1...12).contains($0.rows) && (1...12).contains($0.columns) && $0.cells.count == $0.rows * $0.columns && $0.cells.allSatisfy({ $0.count <= 2_000 }) }), Set(saved.objects.map(\.id)).count == saved.objects.count else { throw ReferenceFailure("Invalid shape settings.") }
            let text = try NSMutableAttributedString(data: saved.text, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            guard text.length <= 200_000 else { throw ReferenceFailure("This document is too long for Writer.") }
            for formula in saved.formulae where formula.location >= 0 && formula.location < text.length && formula.source.utf8.count <= 10_000 { text.addAttribute(.init("remile.formula"), value: formula.source, range: NSRange(location: formula.location, length: 1)) }
            model.load(text: text, objects: saved.objects, paper: saved.paper, landscape: saved.landscape, pageStyle: pageStyle)
            return true
        } else {
            // Preserve unknown objects rather than silently discarding them during editing.
            let xml = String(decoding: try archive.read("word/document.xml"), as: UTF8.self)
            guard !xml.contains(":drawing"), !xml.contains(":pict"), !xml.contains(":tbl"), !xml.contains(":oMath"), !xml.contains("headerReference"), !xml.contains("footerReference") else { throw ReferenceFailure("This DOCX has unsupported layout. Open it in Word or convert it to PDF.") }
            let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
            guard text.length <= 200_000 else { throw ReferenceFailure("This document is too long for Writer.") }
            model.load(text: text, objects: [], paper: PaperSize.a4.rawValue, landscape: false)
            return false
        }
    }
    private static func zip(_ parts: [String: Data]) throws -> Data {
        var output = Data(), central = Data()
        func append(_ number: Int, _ bytes: Int, to data: inout Data) { for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: number >> (index * 8))) } }
        for key in parts.keys.sorted() {
            let data = parts[key]!, name = Data(key.utf8), start = output.count
            let crc = data.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            append(0x04034b50, 4, to: &output); for n in [20, 0x800, 0, 0, 0] { append(n, 2, to: &output) }; for n in [crc, data.count, data.count] { append(n, 4, to: &output) }; append(name.count, 2, to: &output); append(0, 2, to: &output); output.append(name); output.append(data)
            append(0x02014b50, 4, to: &central); for n in [20, 20, 0x800, 0, 0, 0] { append(n, 2, to: &central) }; for n in [crc, data.count, data.count] { append(n, 4, to: &central) }; for n in [name.count, 0, 0, 0, 0] { append(n, 2, to: &central) }; append(0, 4, to: &central); append(start, 4, to: &central); central.append(name)
        }
        let start = output.count; output.append(central); append(0x06054b50, 4, to: &output); for n in [0, 0, parts.count, parts.count] { append(n, 2, to: &output) }; append(central.count, 4, to: &output); append(start, 4, to: &output); append(0, 2, to: &output)
        guard output.count <= 32_000_000 else { throw ReferenceFailure("This Writer document exceeds 32 MB.") }; return output
    }
}
