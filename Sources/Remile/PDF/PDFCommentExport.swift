import Foundation
import PDFKit

/// Portable review data. Document names deliberately omit local paths.
enum PDFCommentExport {
    struct Archive: Codable, Sendable {
        var schemaVersion = 1
        let document: String
        let comments: [Comment]
    }
    struct Comment: Codable, Sendable {
        let id: String
        let page: Int
        let kind: String
        let author: String?
        let text: String
        let quote: String?
        let modified: String?
        let replyTo: String?
    }
    enum Format: String { case markdown, json }
    static func format(named name: String?, output: String?) throws -> Format {
        let value = name ?? (output.map { ($0 as NSString).pathExtension.lowercased() } ?? "json")
        switch value { case "md", "markdown": return .markdown; case "json": return .json; default: throw CocoaError(.fileWriteInapplicableStringEncoding) }
    }
    static func response(_ archive: Archive, format: Format, output: String?) throws -> [String: Any] {
        let bytes = try data(archive, format: format)
        if let output {
            let target = URL(fileURLWithPath: output)
            guard output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output), target.pathExtension.lowercased() == (format == .json ? "json" : "md") else { throw CocoaError(.fileWriteFileExists) }
            try bytes.write(to: target, options: .atomic)
            return ["ok": true, "output": output, "count": archive.comments.count, "format": format.rawValue]
        }
        if format == .markdown { return ["ok": true, "document": archive.document, "count": archive.comments.count, "markdown": String(decoding: bytes, as: UTF8.self)] }
        var result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]; result["ok"] = true; return result
    }
    static func isReviewComment(_ annotation: PDFAnnotation) -> Bool {
        let types: Set<String> = ["Text", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight", "Underline", "Squiggly", "StrikeOut", "Stamp", "Caret", "Ink", "FileAttachment", "Sound", "Redact"]
        if ["Highlight", "Underline", "Squiggly", "StrikeOut"].contains(annotation.type ?? ""), annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "IRT")) == nil { return false }
        return types.contains(annotation.type ?? "") && annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    static func capture(_ document: PDFDocument, name: String, graph supplied: PDFCommentGraph? = nil) throws -> Archive {
        guard !document.isLocked, document.allowsCopying else { throw CocoaError(.fileReadNoPermission) }
        let graph = supplied ?? PDFCommentGraph(document: document)
        var parents = rawParents(document)
        for (child, parent) in graph.parents { parents[child] = parent }
        var ids: [ObjectIdentifier: String] = [:], annotations: [(PDFAnnotation, PDFPage, Int)] = []
        for number in 0..<document.pageCount {
            guard let page = document.page(at: number) else { continue }
            for (index, annotation) in page.annotations.enumerated() where annotation.type != "Popup" {
                ids[ObjectIdentifier(annotation)] = "p\(number + 1)-a\(index + 1)"
                annotations.append((annotation, page, number + 1))
            }
        }
        var included = Set(annotations.filter { isReviewComment($0.0) || (parents[ObjectIdentifier($0.0)] != nil && ["Highlight", "Underline", "Squiggly", "StrikeOut"].contains($0.0.type ?? "") && $0.0.contents?.isEmpty == false) }.map { ObjectIdentifier($0.0) })
        var pending = Array(included)
        while let child = pending.popLast() { if let parent = parents[child], included.insert(parent).inserted { pending.append(parent) } }
        let date = ISO8601DateFormatter()
        let comments = annotations.compactMap { annotation, page, number -> Comment? in
            let identity = ObjectIdentifier(annotation)
            guard included.contains(identity), let id = ids[identity] else { return nil }
            let kind = annotation.type ?? "Text"
            let quote = ["Highlight", "Underline", "Squiggly", "StrikeOut"].contains(kind) ? page.selection(for: annotation.bounds)?.string : nil
            return Comment(id: id, page: number, kind: kind, author: annotation.userName?.isEmpty == false ? annotation.userName : nil, text: annotation.contents ?? "", quote: quote, modified: annotation.modificationDate.map(date.string(from:)), replyTo: parents[identity].flatMap { ids[$0] })
        }
        return Archive(document: URL(fileURLWithPath: name).lastPathComponent, comments: comments)
    }
    /// Resolve imported reply references across pages without rewriting the PDF.
    private static func rawParents(_ document: PDFDocument) -> [ObjectIdentifier: ObjectIdentifier] {
        var identities: [UInt: ObjectIdentifier] = [:], links: [(ObjectIdentifier, UInt)] = []
        for number in 0..<document.pageCount {
            guard let page = document.page(at: number), let dictionary = page.pageRef?.dictionary else { continue }
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Annots", &array), let array else { continue }
            let annotations = page.annotations.filter { $0.type != "Popup" }
            var mappings: [(PDFAnnotation, CGPDFDictionaryRef)] = []
            var valid = true
            for index in 0..<CGPDFArrayGetCount(array) {
                var raw: CGPDFDictionaryRef?, type: UnsafePointer<CChar>?
                guard CGPDFArrayGetDictionary(array, index, &raw), let raw, CGPDFDictionaryGetName(raw, "Subtype", &type), let type else { valid = false; break }
                let name = String(cString: type)
                if name == "Popup" { continue }
                guard mappings.count < annotations.count, annotations[mappings.count].type == name else { valid = false; break }
                mappings.append((annotations[mappings.count], raw))
            }
            guard valid, mappings.count == annotations.count else { continue }
            for (annotation, raw) in mappings {
                let id = ObjectIdentifier(annotation); identities[UInt(bitPattern: raw.rawValue)] = id
                var parent: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(raw, "IRT", &parent), let parent { links.append((id, UInt(bitPattern: parent.rawValue))) }
            }
        }
        return Dictionary(links.compactMap { child, parent in identities[parent].map { (child, $0) } }, uniquingKeysWith: { _, latest in latest })
    }
    static func data(_ archive: Archive, format: Format) throws -> Data {
        if format == .json { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(archive) }
        func escape(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        var lines = ["# Comments — " + escape(archive.document), ""]
        if archive.comments.isEmpty { lines += ["No comments.", ""] }
        for comment in archive.comments {
            lines += ["## Page \(comment.page) · \(escape(comment.author ?? "Unknown author"))", "", "ID: `\(comment.id)`"]
            if let parent = comment.replyTo { lines += ["Reply to: `\(parent)`"] }
            if let modified = comment.modified { lines += ["Modified: \(modified)"] }
            lines += [""]
            if let quote = comment.quote, !quote.isEmpty { lines += quote.components(separatedBy: .newlines).map { "> " + escape($0) }; lines += [""] }
            // Quotes keep authored text as content rather than document headings or HTML.
            lines += comment.text.components(separatedBy: .newlines).map { "> " + escape($0) }
            lines += [""]
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
