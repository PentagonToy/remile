import Foundation

/// A bounded lexical scan for source edits, not a TeX macro interpreter.
enum TeXSourceTools {
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
        for range in try scan(source).comments {
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
    static func inlineBibliography(_ source: String, bbl: String) throws -> String {
        guard bbl.utf8.count <= 4_000_000, bbl.contains("\\begin{thebibliography}"), bbl.contains("\\end{thebibliography}"), !bbl.contains("\\refsection") else { throw Failure(errorDescription: "This bibliography is not a classic BibTeX bibliography. biblatex/Biber output cannot be embedded this way.") }
        let commands = try commands(source), value = source as NSString
        let bibliographies = commands.filter { $0.name == "bibliography" }
        guard bibliographies.count == 1, !commands.contains(where: { $0.name == "printbibliography" || $0.name == "addbibresource" }) else { throw Failure(errorDescription: "Choose a main document with one classic \\bibliography command. Split or biblatex bibliographies need a different submission workflow.") }
        var edits: [(NSRange, String)] = []
        for command in commands where command.name == "bibliography" || command.name == "bibliographystyle" {
            let end = try argument(value, from: NSMaxRange(command.range)).end
            edits.append((NSRange(location: command.range.location, length: end - command.range.location), command.name == "bibliography" ? bbl.trimmingCharacters(in: .whitespacesAndNewlines) : ""))
        }
        let changed = NSMutableString(string: source)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) { changed.replaceCharacters(in: range, with: replacement) }
        return changed as String
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
