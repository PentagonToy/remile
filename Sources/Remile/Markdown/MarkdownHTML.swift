import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Escaped, self-contained HTML: local images are embedded, never requested by WebKit.
struct MarkdownHTML {
    enum Failure: LocalizedError {
        case image(String), remoteImage, markup, tooLarge, empty
        var errorDescription: String? {
            switch self {
            case .image(let name): return "Image unavailable: \(name)"
            case .remoteImage: return "Remote images require a local copy."
            case .markup: return "Unclosed Markdown block."
            case .empty: return "Empty document."
            case .tooLarge: return "Document exceeds the conversion limit."
            }
        }
    }
    let baseURL: URL
    private var references: [String: String] = [:]
    private var imageBytes = 0
    init(baseURL: URL) { self.baseURL = baseURL }

    mutating func document(_ source: String, anchors: [Int: Int] = [:]) throws -> String {
        guard source.utf8.count <= 8_000_000 else { throw Failure.tooLarge }
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let end = line.range(of: "]:"), !line.hasPrefix("![") {
                let key = String(line[line.index(after: line.startIndex)..<end.lowerBound]).lowercased()
                references[key] = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                lines[index] = ""
            }
        }
        var html = "", index = 0
        while index < lines.count {
            try Task.checkCancellation()
            html += "<span class=\"source-anchor\" data-source-line=\"\(index)\" id=\"source-line-\(index)\"></span>"
            if let section = anchors[index] { html += "<span id=\"section-\(section)\"></span>" }
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { index += 1; continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let fence = String(line.prefix(3)), language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1; var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[index]); index += 1 }
                guard index < lines.count else { throw Failure.markup }; index += 1
                if ["math", "latex", "tex"].contains(language.lowercased()) { html += try MathMarkup.render(code.joined(separator: "\n"), display: true) }
                else { html += "<pre><code>\(MathMarkup.escape(code.joined(separator: "\n")))</code></pre>" }
                continue
            }
            if line.hasPrefix("$$") || line.hasPrefix("\\[") {
                let opening = line.hasPrefix("$$") ? "$$" : "\\[", closing = opening == "$$" ? "$$" : "\\]"
                var formula = String(line.dropFirst(2))
                index += 1
                if formula.hasSuffix(closing) { formula = String(formula.dropLast(2)) }
                else {
                    var found = false
                    while index < lines.count {
                        let next = lines[index]; index += 1
                        if let end = next.range(of: closing) { formula += "\n" + next[..<end.lowerBound]; found = true; break }
                        formula += "\n" + next
                    }
                    guard found else { throw Failure.markup }
                }
                html += try MathMarkup.render(formula, display: true); continue
            }
            if index + 1 < lines.count, let alignments = Self.tableRule(lines[index + 1]), line.contains("|") {
                let headers = Self.cells(line)
                html += "<table><thead><tr>"
                for (column, cell) in headers.enumerated() { html += "<th style=\"text-align:\(alignments[min(column, alignments.count - 1)])\">\(try inline(cell))</th>" }
                html += "</tr></thead><tbody>"; index += 2
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty && lines[index].contains("|") {
                    let row = Self.cells(lines[index]); html += "<tr>"
                    for column in headers.indices { html += "<td style=\"text-align:\(alignments[min(column, alignments.count - 1)])\">\(try inline(column < row.count ? row[column] : ""))</td>" }
                    html += "</tr>"; index += 1
                }
                html += "</tbody></table>"; continue
            }
            let heading = line.prefix(while: { $0 == "#" }).count
            if heading > 0 && heading <= 6 && line.dropFirst(heading).hasPrefix(" ") {
                html += "<h\(heading)>\(try inline(String(line.dropFirst(heading + 1))))</h\(heading)>"; index += 1; continue
            }
            if ["---", "***", "___"].contains(line) { html += "<hr>"; index += 1; continue }
            if line.hasPrefix(">") { html += "<blockquote>\(try inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>"; index += 1; continue }
            if Self.listItem(line) != nil {
                let ordered = Self.listItem(line)!.1
                let tag = ordered ? "ol" : "ul"; html += "<\(tag)>"
                while index < lines.count, let item = Self.listItem(lines[index].trimmingCharacters(in: .whitespaces)), item.1 == ordered {
                    html += "<li>\(try inline(item.0))</li>"; index += 1
                }
                html += "</\(tag)>"; continue
            }
            var paragraph = line; index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("#") || next.hasPrefix("```") || next.hasPrefix("~~~") || next.hasPrefix("$$") || next.hasPrefix("\\[") || next.hasPrefix(">") || Self.listItem(next) != nil || ["---", "***", "___"].contains(next) { break }
                if index + 1 < lines.count && Self.tableRule(lines[index + 1]) != nil { break }
                paragraph += "\n" + next; index += 1
            }
            html += "<p>\(try inline(paragraph))</p>"
        }
        guard !html.isEmpty else { throw Failure.empty }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; base-uri 'none'"><style>
        @page { size:letter; margin:36pt; } *{box-sizing:border-box}html,body{margin:0;padding:0;background:white;color:#171c20}body{font:11pt -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.5;overflow-wrap:anywhere}h1,h2,h3,h4,h5,h6{line-height:1.2;break-after:avoid;margin:1em 0 .5em}h1{font-size:24pt}h2{font-size:19pt}h3{font-size:15pt}p{margin:.65em 0}pre{background:#f2f3f4;padding:10pt;white-space:pre-wrap;overflow-wrap:anywhere}code{font:10pt ui-monospace,monospace}blockquote{border-left:3pt solid #c9c9c9;margin:10pt 0;padding-left:12pt}table{width:100%;border-collapse:collapse;margin:12pt 0;table-layout:fixed}thead{display:table-header-group}tr{break-inside:avoid}th,td{border:0.5pt solid #b8b8b8;padding:6pt;vertical-align:top}th{background:#eee}img{display:inline-block;max-width:100%;max-height:650pt;object-fit:contain;vertical-align:middle;break-inside:avoid}math[display=block]{margin:12pt 0;break-inside:avoid;font-size:13pt}math{font-family:"STIX Two Math","STIXGeneral","Times New Roman",serif}hr{border:0;border-top:1pt solid #bbb}a{color:inherit;text-decoration:underline}
        </style></head><body>\(html)</body></html>
        """
    }

    private static func tableRule(_ line: String) -> [String]? {
        let columns = cells(line)
        guard !columns.isEmpty && columns.count <= 32 else { return nil }
        var result: [String] = []
        for column in columns {
            let value = column.trimmingCharacters(in: .whitespaces)
            guard value.filter({ $0 == "-" }).count >= 3 && value.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            result.append(value.hasSuffix(":") ? value.hasPrefix(":") ? "center" : "right" : "left")
        }
        return result
    }
    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") { text.removeLast() }
        var result: [String] = [], cell = "", escaped = false, code = false
        for character in text {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { cell.append(character); escaped = true; continue }
            if character == "`" { code.toggle() }
            if character == "|" && !code { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        result.append(cell.trimmingCharacters(in: .whitespaces)); return result
    }
    private static func listItem(_ line: String) -> (String, Bool)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return (String(line.dropFirst(2)), false) }
        let digits = line.prefix(while: \.isNumber).count
        if digits > 0 && (line.dropFirst(digits).hasPrefix(". ") || line.dropFirst(digits).hasPrefix(") ")) { return (String(line.dropFirst(digits + 2)), true) }
        return nil
    }

    private mutating func inline(_ source: String) throws -> String {
        let chars = Array(source); var position = 0, plain = "", result = ""
        func styled(_ text: String) -> String {
            guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return MathMarkup.escape(text) }
            var html = ""
            for run in parsed.runs {
                var piece = MathMarkup.escape(String(parsed[run.range].characters))
                let intent = run.inlinePresentationIntent
                if intent?.contains(.code) == true { piece = "<code>\(piece)</code>" }
                if intent?.contains(.stronglyEmphasized) == true { piece = "<strong>\(piece)</strong>" }
                if intent?.contains(.emphasized) == true { piece = "<em>\(piece)</em>" }
                if intent?.contains(.strikethrough) == true { piece = "<del>\(piece)</del>" }
                if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                    piece = "<a href=\"\(MathMarkup.escape(link.absoluteString))\">\(piece)</a>"
                }
                html += piece
            }
            return html
        }
        while position < chars.count {
            if chars[position...].starts(with: Array("<br>")) || chars[position...].starts(with: Array("<br/>")) {
                result += styled(plain) + "<br>"; plain = ""
                position += chars[position...].starts(with: Array("<br/>")) ? 5 : 4; continue
            }
            if chars[position] == "`" {
                let start = position; position += 1
                while position < chars.count && chars[position] != "`" { position += 1 }
                if position < chars.count { position += 1 }
                plain += String(chars[start..<position]); continue
            }
            if chars[position] == "\\", position + 1 < chars.count, chars[position + 1] == "$" {
                plain += "$"; position += 2; continue
            }
            let slashMath = chars[position] == "\\" && position + 1 < chars.count && chars[position + 1] == "("
            if chars[position] == "$" || slashMath {
                let start = position, width = slashMath ? 2 : 1
                var end = position + width
                while end < chars.count {
                    if slashMath ? chars[end] == "\\" && end + 1 < chars.count && chars[end + 1] == ")" : chars[end] == "$" { break }
                    if chars[end] == "\\" { end += 1 }; end += 1
                }
                if end < chars.count {
                    result += styled(plain); plain = ""
                    result += try MathMarkup.render(String(chars[(start + width)..<end]), display: false)
                    position = end + width; continue
                }
            }
            if chars[position] == "!", position + 1 < chars.count, chars[position + 1] == "[", let end = chars[(position + 2)...].firstIndex(of: "]") {
                let alt = String(chars[(position + 2)..<end]); var next = end + 1, path: String?
                if next < chars.count && chars[next] == "(" {
                    next += 1; let start = next; var depth = 1
                    while next < chars.count {
                        if chars[next] == "(" { depth += 1 }; if chars[next] == ")" { depth -= 1; if depth == 0 { break } }; next += 1
                    }
                    if next < chars.count { path = String(chars[start..<next]); next += 1 }
                } else if next < chars.count && chars[next] == "[", let closing = chars[(next + 1)...].firstIndex(of: "]") {
                    let key = String(chars[(next + 1)..<closing]); path = references[(key.isEmpty ? alt : key).lowercased()]; next = closing + 1
                } else { path = references[alt.lowercased()] }
                if let path {
                    result += styled(plain); plain = ""
                    result += "<img alt=\"\(MathMarkup.escape(alt))\" src=\"\(try embeddedImage(path))\">"
                    position = next; continue
                }
                throw Failure.image(alt)
            }
            plain.append(chars[position]); position += 1
        }
        return result + styled(plain)
    }

    private mutating func embeddedImage(_ reference: String) throws -> String {
        var path = reference.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("<"), let end = path.firstIndex(of: ">") { path = String(path[path.index(after: path.startIndex)..<end]) }
        else if let title = path.range(of: " \"") { path = String(path[..<title.lowerBound]) }
        let data: Data
        if path.hasPrefix("data:image/"), let comma = path.firstIndex(of: ","), path[..<comma].hasSuffix(";base64"), let decoded = Data(base64Encoded: String(path[path.index(after: comma)...])) { data = decoded }
        else {
            guard let url = URL(string: path, relativeTo: baseURL.deletingLastPathComponent())?.absoluteURL, url.isFileURL else { throw Failure.remoteImage }
            let root = baseURL.deletingLastPathComponent().resolvingSymlinksInPath().path
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root + "/") else { throw Failure.image(path) }
            let size = try resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 30_000_000 else { throw Failure.tooLarge }
            guard let bytes = try? Data(contentsOf: resolved) else { throw Failure.image(path) }; data = bytes
        }
        guard data.count <= 30_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4800] as CFDictionary) else { throw Failure.image(path) }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw Failure.image(path) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.image(path) }
        imageBytes += bytes.length; guard imageBytes <= 60_000_000 else { throw Failure.tooLarge }
        return "data:image/png;base64," + (bytes as Data).base64EncodedString()
    }
}
