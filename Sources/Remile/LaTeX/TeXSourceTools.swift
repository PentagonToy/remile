import Foundation

/// A bounded lexical scan for source edits, not a TeX macro interpreter.
enum TeXSourceTools {
    private static let bibliographyMarker = "% remile-bib:v1 "
    struct Command { let name: String; let range: NSRange }
    struct Failure: LocalizedError { let errorDescription: String? }
    static func commands(_ source: String) throws -> [Command] { try scan(source).commands }
    private static func scan(_ source: String) throws -> (commands: [Command], comments: [NSRange]) {
        let value = source as NSString
        guard value.length <= 4_000_000 else { throw Failure(errorDescription: "This source is too large for a bulk edit.") }
        var result: [Command] = [], comments: [NSRange] = [], i = 0
        while i < value.length {
            let c = value.character(at: i)
            if c == 37 { let start = i; while i < value.length && value.character(at: i) != 10 && value.character(at: i) != 13 { i += 1 }; comments.append(NSRange(location: start, length: i - start)); continue }
            guard c == 92 else { i += 1; continue }
            let start = i; i += 1
            guard i < value.length else { break }
            if !letter(value.character(at: i)) { i += 1; continue }
            let nameStart = i
            while i < value.length && letter(value.character(at: i)) { i += 1 }
            let name = value.substring(with: NSRange(location: nameStart, length: i - nameStart))
            if name == "verb" {
                if i < value.length && value.character(at: i) == 42 { i += 1 }
                if i < value.length { let delimiter = value.character(at: i); i += 1; while i < value.length && value.character(at: i) != delimiter && value.character(at: i) != 10 { i += 1 }; i = min(value.length, i + 1) }
                continue
            }
            if name == "begin", let arg = try? argument(value, from: i, opening: 123, closing: 125), ["verbatim", "verbatim*", "lstlisting", "minted", "comment"].contains(arg.text) {
                let end = value.range(of: "\\end{" + arg.text + "}", range: NSRange(location: arg.end, length: value.length - arg.end))
                guard end.location != NSNotFound else { throw Failure(errorDescription: "Close the verbatim or comment environment before editing.") }
                i = NSMaxRange(end); continue
            }
            result.append(Command(name: name, range: NSRange(location: start, length: i - start)))
        }
        return (result, comments)
    }
    static func removingAuthorNotes(_ source: String) throws -> (source: String, count: Int) {
        let value = source as NSString
        var edits: [NSRange] = []
        var inEmbeddedBibliography = false
        for range in try scan(source).comments {
            let comment = value.substring(with: range)
            if comment.hasPrefix(bibliographyMarker) {
                if comment.hasPrefix(bibliographyMarker + "begin ") { inEmbeddedBibliography = true }
                if comment == bibliographyMarker + "end" { inEmbeddedBibliography = false }
                continue
            }
            guard !inEmbeddedBibliography else { continue }
            let note = value.substring(with: NSRange(location: range.location + 1, length: range.length - 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty, !note.lowercased().hasPrefix("!tex"), !note.hasPrefix("&") else { continue }
            let line = value.lineRange(for: range)
            let prefix = value.substring(with: NSRange(location: line.location, length: range.location - line.location))
            if prefix.trimmingCharacters(in: .whitespaces).isEmpty { edits.append(line) }
            else { edits.append(NSRange(location: range.location + 1, length: range.length - 1)) }
        }
        let changed = NSMutableString(string: source)
        for range in edits.reversed() { changed.replaceCharacters(in: range, with: "") }
        return (changed as String, edits.count)
    }
    static func hasEmbeddedBibliography(_ source: String) -> Bool {
        source.contains(bibliographyMarker + "begin ")
    }
    static func inlineBibliography(_ source: String, bbl: String, keepOrigin: Bool = false) throws -> String {
        guard bbl.utf8.count <= 4_000_000, bbl.contains("\\begin{thebibliography}"), bbl.contains("\\end{thebibliography}"), !bbl.contains("\\refsection") else { throw Failure(errorDescription: "This bibliography is not a classic BibTeX bibliography. biblatex/Biber output cannot be embedded this way.") }
        let commands = try commands(source), value = source as NSString
        let bibliographies = commands.filter { $0.name == "bibliography" }
        guard bibliographies.count == 1, !commands.contains(where: { $0.name == "printbibliography" || $0.name == "addbibresource" }) else { throw Failure(errorDescription: "Choose a main document with one classic \\bibliography command. Split or biblatex bibliographies need a different submission workflow.") }
        let body = bbl.trimmingCharacters(in: .whitespacesAndNewlines)
        let originals = try commands.filter { ["bibliography", "bibliographystyle"].contains($0.name) }.map { command in
            let end = try argument(value, from: NSMaxRange(command.range)).end
            let range = NSRange(location: command.range.location, length: end - command.range.location)
            let encoded = keepOrigin ? Data(value.substring(with: range).utf8).base64EncodedString() : ""
            return (name: command.name, range: range, encoded: encoded)
        }
        let styles = originals.filter { $0.name == "bibliographystyle" }.map(\.encoded)
        let edits = originals.map { item in
            let replacement: String
            if item.name == "bibliography" {
                replacement = keepOrigin
                    ? bibliographyMarker + "begin " + item.encoded + " " + bibliographyDigest(body, command: item.encoded, styles: styles) + "\n" + body + "\n" + bibliographyMarker + "end\n"
                    : body
            } else {
                replacement = keepOrigin ? bibliographyMarker + "style " + item.encoded + "\n" : ""
            }
            return (item.range, replacement)
        }
        let changed = NSMutableString(string: source)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) { changed.replaceCharacters(in: range, with: replacement) }
        let text = changed as String
        guard !keepOrigin || text.utf8.count <= 4_000_000 else {
            throw Failure(errorDescription: "The embedded source would be too large to restore.")
        }
        return text
    }
    static func restoreBibliography(_ source: String) throws -> (source: String, references: [String]) {
        let value = source as NSString
        let markers = try scan(source).comments.compactMap { range -> (NSRange, [Substring])? in
            let line = value.substring(with: range)
            guard line.hasPrefix(bibliographyMarker) else { return nil }
            return (range, line.dropFirst(bibliographyMarker.count).split(separator: " "))
        }
        let begins = markers.filter { $0.1.first == "begin" }
        let ends = markers.filter { $0.1.first == "end" }
        let failure = Failure(errorDescription: "The embedded references or their recovery markers changed. Keep the source and review it manually.")
        guard !markers.isEmpty else { throw Failure(errorDescription: "No restorable bibliography was embedded by remile.") }
        guard begins.count == 1, ends.count == 1, let (begin, fields) = begins.first, fields.count == 3,
              let (end, endFields) = ends.first, endFields.count == 1,
              let bodyStart = markerEnd(begin, in: value), let blockEnd = markerEnd(end, in: value),
              end.location > bodyStart, value.character(at: end.location - 1) == 10 else { throw failure }
        let body = value.substring(with: NSRange(location: bodyStart, length: end.location - bodyStart - 1))
        guard let (command, list) = originalBibliographyCommand(fields[1], named: "bibliography") else { throw failure }
        let names = list.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty && !$0.contains("\\") && !$0.contains("{") && !$0.contains("}") }) else { throw failure }
        let references = names.map { $0.lowercased().hasSuffix(".bib") ? $0 : $0 + ".bib" }
        var edits = [(NSRange(location: begin.location, length: blockEnd - begin.location), command)]
        var styles: [String] = []
        for (range, parts) in markers where range != begin && range != end {
            guard range.location < begin.location || range.location >= blockEnd, parts.count == 2, parts[0] == "style",
                  let lineEnd = markerEnd(range, in: value),
                  let (style, _) = originalBibliographyCommand(parts[1], named: "bibliographystyle") else { throw failure }
            edits.append((NSRange(location: range.location, length: lineEnd - range.location), style))
            styles.append(String(parts[1]))
        }
        guard bibliographyDigest(body, command: String(fields[1]), styles: styles) == fields[2] else { throw failure }
        let restored = NSMutableString(string: source)
        for (range, command) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            restored.replaceCharacters(in: range, with: command)
        }
        let text = restored as String
        guard try commands(text).filter({ $0.name == "bibliography" }).count == 1 else { throw failure }
        return (text, references)
    }
    private static func bibliographyDigest(_ body: String, command: String, styles: [String]) -> String {
        SourceDigest.sha256(([command] + styles + [body]).joined(separator: "\n"))
    }
    private static func markerEnd(_ range: NSRange, in text: NSString) -> Int? {
        let end = NSMaxRange(range)
        guard end < text.length, text.character(at: end) == 10 else { return nil }
        return end + 1
    }
    private static func originalBibliographyCommand(_ encoded: Substring, named name: String) -> (String, String)? {
        guard let data = Data(base64Encoded: String(encoded)), let command = String(data: data, encoding: .utf8),
              let items = try? commands(command), items.count == 1, let first = items.first,
              first.name == name, first.range.location == 0 else { return nil }
        let value = command as NSString
        guard let arg = try? argument(value, from: NSMaxRange(first.range), opening: 123, closing: 125),
              arg.end == value.length else { return nil }
        return (command, arg.text)
    }
    private static func letter(_ c: UInt16) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 64 }
    private static func skipSpace(_ value: NSString, _ from: Int) -> Int {
        var i = from
        while i < value.length {
            if [9, 10, 13, 32].contains(value.character(at: i)) { i += 1 }
            else if value.character(at: i) == 37 { while i < value.length && value.character(at: i) != 10 { i += 1 } }
            else { break }
        }
        return i
    }
    private static func argument(_ value: NSString, from: Int, opening: UInt16 = 123, closing: UInt16 = 125) throws -> (text: String, end: Int) {
        var i = skipSpace(value, from)
        guard i < value.length, value.character(at: i) == opening else { throw Failure(errorDescription: "An incomplete TeX argument prevents this edit.") }
        let start = i + 1; i += 1; var depth = 1, braces = 0
        while i < value.length {
            let c = value.character(at: i)
            if c == 92 { i = min(value.length, i + 2); continue }
            if c == 37 { while i < value.length && value.character(at: i) != 10 { i += 1 }; continue }
            if opening == 91 { if c == 123 { braces += 1 }; if c == 125 { braces -= 1 } }
            if braces == 0 { if c == opening { depth += 1 }; if c == closing { depth -= 1 } }
            if depth == 0 { return (value.substring(with: NSRange(location: start, length: i - start)), i + 1) }
            i += 1
        }
        throw Failure(errorDescription: "An unclosed TeX argument prevents this edit.")
    }
}
