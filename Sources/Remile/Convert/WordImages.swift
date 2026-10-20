import AppKit
import ImageIO

/// Substitute image placeholders before system import, then attach decoded local package images.
final class WordImages: NSObject, XMLParserDelegate {
    struct Picture { let token: String; let relationship: String; let size: NSSize }
    private var xml = ""
    private var depth = 0
    private var skipped: Int?
    private var drawingXML = ""
    private var relationship: String?
    private var size = NSSize.zero
    private var pictures: [Picture] = []
    private var equations: [(String, String, Bool)] = []
    private var mathXML: String?
    private var mathDepth: Int?
    private var paragraphDepth = 0
    private var relationships: [String: String] = [:]
    private var external = Set<String>()
    private var readingRelationships = false
    private var unsupported = false
    private var reason: String?
    private static let unsupportedFeatures = ["altChunk": "Embedded documents", "txbxContent": "Word text boxes", "chart": "Word charts", "instrText": "Word fields", "footnoteReference": "Word footnotes", "endnoteReference": "Word endnotes", "fldSimple": "Word fields", "del": "Tracked changes", "ins": "Tracked changes", "sdt": "Word content controls"]
    private var nodes = 0
    private var sections = 0
    private let prefix = "REMILE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    enum Failure: LocalizedError {
        case unsupported, missing, feature(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "This Word document contains unsupported objects."
            case .missing: return "A Word image could not be loaded."
            case .feature(let message): return message
            }
        }
    }
    static func load(_ url: URL, attributes: inout NSDictionary?) async throws -> NSAttributedString {
        try await load(WordArchive(Data(contentsOf: url)), part: "word/document.xml", attributes: &attributes)
    }
    static func load(_ archive: WordArchive, part: String, sourceXML: Data? = nil, attributes: inout NSDictionary?) async throws -> NSAttributedString {
        let bridge = WordImages()
        let source = try sourceXML ?? archive.read(part)
        let directory = (part as NSString).deletingLastPathComponent
        let relPart = directory + "/_rels/" + (part as NSString).lastPathComponent + ".rels"
        bridge.readingRelationships = true
        if archive.entries.contains(where: { $0.name == relPart }) { try bridge.parse(archive.read(relPart)) }
        bridge.readingRelationships = false; bridge.nodes = 0
        try bridge.parse(source)
        guard !bridge.unsupported else { throw bridge.reason.map(Failure.feature) ?? Failure.unsupported }
        var markup = bridge.xml
        if part != "word/document.xml" {
            let root = try WordXML.parse(Data(markup.utf8))
            let prefix = root.name.split(separator: ":").dropLast().joined(separator: ":")
            let document = WordXML.Node(prefix.isEmpty ? "document" : prefix + ":document", attributes: root.attributes)
            let body = WordXML.Node(prefix.isEmpty ? "body" : prefix + ":body"); body.content = root.content; document.content = [.node(body)]
            markup = document.xml
        }
        var patched = archive.replacing("word/document.xml", with: Data(markup.utf8))
        if part != "word/document.xml", archive.entries.contains(where: { $0.name == "word/_rels/document.xml.rels" }) {
            let relationships = archive.entries.contains(where: { $0.name == relPart }) ? try archive.read(relPart) : Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"/>".utf8)
            patched = try WordArchive(patched).replacing("word/_rels/document.xml.rels", with: relationships)
        }
        let imported = try NSMutableAttributedString(data: patched, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: &attributes)
        var pixels = 0
        for picture in bridge.pictures {
            try Task.checkCancellation()
            guard !bridge.external.contains(picture.relationship), let target = bridge.relationships[picture.relationship],
                  !target.contains(":"), !target.contains("\\"), !target.contains("%") else { throw Failure.missing }
            var parts = target.hasPrefix("/") ? [String]() : directory.split(separator: "/").map(String.init)
            for part in target.split(separator: "/") {
                if part == ".." { guard !parts.isEmpty else { throw Failure.missing }; parts.removeLast() }
                else if part != "." { parts.append(String(part)) }
            }
            let bytes = try archive.read(parts.joined(separator: "/"))
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4800] as CFDictionary) else { throw Failure.missing }
            pixels += image.width * image.height
            guard pixels <= 40_000_000 else { throw WordArchive.Failure.limit }
            let size = picture.size.width > 0 && picture.size.height > 0 ? picture.size : NSSize(width: image.width, height: image.height)
            let attachment = NSTextAttachment()
            attachment.attachmentCell = await MainActor.run { NSTextAttachmentCell(imageCell: NSImage(cgImage: image, size: size)) }
            let range = (imported.string as NSString).range(of: picture.token)
            guard range.location != NSNotFound else { throw Failure.missing }
            let replacement = NSMutableAttributedString(attachment: attachment)
            if range.length > 0 { replacement.addAttributes(imported.attributes(at: range.location, effectiveRange: nil), range: NSRange(location: 0, length: replacement.length)); replacement.addAttribute(.attachment, value: attachment, range: NSRange(location: 0, length: replacement.length)) }
            imported.replaceCharacters(in: range, with: replacement)
        }
        var integralLimits = "subSup", naryLimits = "undOvr"
        if !bridge.equations.isEmpty, archive.entries.contains(where: { $0.name == "word/settings.xml" }) {
            let settings = try WordXML.parse(archive.read("word/settings.xml"))
            if let properties = settings.child("mathPr") {
                integralLimits = properties.child("intLim")?.attribute("val") ?? integralLimits
                naryLimits = properties.child("naryLim")?.attribute("val") ?? naryLimits
            }
        }
        for (token, source, math) in bridge.equations {
            let node = try WordXML.parse(Data(source.utf8))
            let markup = try math ? WordMath.markup(node, integralLimits: integralLimits, naryLimits: naryLimits) : WordShape.markup(node)
            let image = try await WordArt.image(markup)
            let attachment = NSTextAttachment(); attachment.attachmentCell = await MainActor.run { NSTextAttachmentCell(imageCell: image) }
            let range = (imported.string as NSString).range(of: token)
            guard range.location != NSNotFound else { throw Failure.unsupported }
            imported.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        }
        return imported
    }
    private func parse(_ data: Data) throws {
        guard data.count <= 20 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw Failure.unsupported }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never; parser.delegate = self
        guard parser.parse(), !unsupported else { throw reason.map(Failure.feature) ?? Failure.unsupported }
    }
    private func local(_ name: String) -> String { String(name.split(separator: ":").last ?? "") }
    private func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1; nodes += 1
        guard depth <= 128, nodes <= 200000 else { unsupported = true; parser.abortParsing(); return }
        let name = local(elementName)
        if name == "p" && mathDepth == nil && skipped == nil { paragraphDepth += 1 }
        if readingRelationships {
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
                relationships[id] = target
                if attributes["TargetMode"] == "External" { external.insert(id) }
            }
            return
        }
        if mathDepth != nil || name == "oMath" || name == "oMathPara" {
            if mathDepth == nil { mathDepth = depth; mathXML = "" }
            mathXML! += "<" + elementName + attributes.keys.sorted().map { " \($0)=\"\(escape(attributes[$0]!))\"" }.joined() + ">"
            return
        }
        if let feature = Self.unsupportedFeatures[name] { unsupported = true; if reason == nil { reason = feature + " are not supported yet." } }
        if name == "sectPr" { sections += 1; if sections > 1 { unsupported = true } }
        if name == "cols", let columns = attributes.first(where: { local($0.key) == "num" })?.value, (Int(columns) ?? 1) > 1 { unsupported = true }
        if name == "tblpPr" { unsupported = true }
        if skipped != nil {
            drawingXML += "<" + elementName + attributes.keys.sorted().map { " \($0)=\"\(escape(attributes[$0]!))\"" }.joined() + ">"
            if name == "srcRect" || (name == "xfrm" && attributes.keys.contains(where: { ["rot", "flipH", "flipV"].contains($0) })) { unsupported = true }
            if name == "blip" { relationship = attributes.first { local($0.key) == "embed" }?.value; if attributes.keys.contains(where: { local($0) == "link" }) { unsupported = true } }
            if name == "shape", let style = attributes["style"] {
                var properties: [String: String] = [:]
                for item in style.split(separator: ";") {
                    let pair = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if pair.count == 2 { properties[pair[0]] = pair[1] }
                }
                if properties["position"] == "absolute" { unsupported = true; reason = "Floating Word previews are not supported yet." }
                func points(_ value: String?) -> Double? {
                    guard let value else { return nil }
                    if value.hasSuffix("pt") { return Double(value.dropLast(2)) }
                    if value.hasSuffix("px"), let number = Double(value.dropLast(2)) { return number * 0.75 }
                    return nil
                }
                if let width = points(properties["width"]), let height = points(properties["height"]), width.isFinite, height.isFinite, width > 0, height > 0 { size = NSSize(width: width, height: height) }
            }
            if name == "imagedata" { relationship = attributes.first { local($0.key) == "id" }?.value }
            if name == "extent", let width = attributes["cx"].flatMap(Double.init), let height = attributes["cy"].flatMap(Double.init), width.isFinite, height.isFinite { size = NSSize(width: width / 12700, height: height / 12700) }
            if name == "anchor" { unsupported = true; reason = "Floating Word images are not supported yet." }
            return
        }
        if name == "drawing" || name == "pict" || name == "object" { skipped = depth; relationship = nil; size = .zero; drawingXML = "<" + elementName + attributes.keys.sorted().map { " \($0)=\"\(escape(attributes[$0]!))\"" }.joined() + ">"; return }
        xml += "<" + elementName
        for key in attributes.keys.sorted() { xml += " " + key + "=\"" + escape(attributes[key]!) + "\"" }
        xml += ">"
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { depth -= 1; if local(elementName) == "p" && mathDepth == nil && skipped == nil { paragraphDepth -= 1 } }
        guard !readingRelationships else { return }
        if let mathDepth {
            mathXML! += "</" + elementName + ">"
            if depth == mathDepth {
                do {
                    guard equations.count < 200 else { throw Failure.unsupported }
                    let token = prefix + "MATH" + String(equations.count)
                    equations.append((token, mathXML!, true))
                    let run = "<w:r xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:t>" + token + "</w:t></w:r>"
                    xml += paragraphDepth > 0 ? run : "<w:p xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" + run + "</w:p>"
                } catch { unsupported = true; reason = error.localizedDescription }
                self.mathDepth = nil; mathXML = nil
            }
            return
        }
        if let skipped {
            drawingXML += "</" + elementName + ">"
            if depth == skipped {
                guard let relationship else {
                    do {
                        guard equations.count < 200 else { throw Failure.unsupported }
                        let token = prefix + "SHAPE" + String(equations.count)
                        equations.append((token, drawingXML, false))
                        xml += "<w:t xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" + token + "</w:t>"
                    } catch { unsupported = true; reason = error.localizedDescription }
                    self.skipped = nil; return
                }
                guard pictures.count < 200 else { unsupported = true; parser.abortParsing(); return }
                let token = prefix + String(pictures.count)
                pictures.append(Picture(token: token, relationship: relationship, size: size))
                // Drawing elements occupy a run. Preserve the run's existing text properties.
                let qualified = elementName.split(separator: ":").dropLast().joined(separator: ":")
                let tag = qualified.isEmpty ? "t" : qualified + ":t"
                xml += "<\(tag)>\(token)</\(tag)>"
                self.skipped = nil
            }
        } else { xml += "</" + elementName + ">" }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { unsupported = true; parser.abortParsing(); return }
        if !readingRelationships && skipped == nil { xml += escape(text) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if mathDepth != nil { mathXML! += escape(string) } else if skipped != nil { drawingXML += escape(string) } else if !readingRelationships && skipped == nil { xml += escape(string) } }
}
