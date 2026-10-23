import Foundation

/// Readable labels without modifying the BibTeX retained for export and editing.
enum ReferenceText {
    static func display(_ source: String) -> String {
        var reader = Reader(chars: Array(source.prefix(100_000)))
        return reader.read().replacingOccurrences(of: "---", with: "—").replacingOccurrences(of: "--", with: "–").split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping
    }
    static func authors(_ source: String) -> [String] {
        let chars = Array(source)
        var result: [String] = [], start = 0, depth = 0, i = 0, escaped = false
        while i < chars.count {
            let c = chars[i]
            if escaped { escaped = false; i += 1; continue }
            if c == "\\" { escaped = true; i += 1; continue }
            if c == "{" { depth += 1 }; if c == "}" { depth = max(0, depth - 1) }
            if depth == 0, i > start, i + 3 < chars.count, chars[i - 1].isWhitespace, String(chars[i..<i + 3]) == "and", chars[i + 3].isWhitespace {
                result.append(String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines)); i += 3; start = i
            } else { i += 1 }
        }
        result.append(String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return result.filter { !$0.isEmpty }
    }
    static func shortAuthors(_ source: String) -> String {
        let names = authors(source)
        guard let first = names.first else { return "" }
        let name: String
        if first.hasPrefix("{"), first.hasSuffix("}") { name = display(first) }
        else if let comma = first.firstIndex(of: ",") { name = display(String(first[..<comma])) }
        else { name = display(first).split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "" }
        return name + (names.count > 1 ? " et al." : "")
    }
    static func field(_ key: String, _ value: String) -> String {
        if ["author", "editor"].contains(key) { return authors(value).map(display).joined(separator: "; ") }
        if ["title", "journal", "booktitle", "publisher", "series", "address", "edition", "note", "keywords", "school", "institution", "organization", "shorttitle"].contains(key) { return display(value) }
        return value
    }
    private struct Reader {
        let chars: [Character]
        var i = 0
        var depth = 0
        static let accents = ["'": "\u{0301}", "`": "\u{0300}", "\"": "\u{0308}", "^": "\u{0302}", "~": "\u{0303}", "=": "\u{0304}", ".": "\u{0307}", "u": "\u{0306}", "v": "\u{030C}", "H": "\u{030B}", "c": "\u{0327}", "k": "\u{0328}", "r": "\u{030A}", "b": "\u{0331}", "d": "\u{0323}"]
        static let symbols = ["ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "aa": "å", "AA": "Å", "o": "ø", "O": "Ø", "ss": "ß", "l": "ł", "L": "Ł", "i": "ı", "j": "ȷ", "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "Delta": "Δ", "epsilon": "ε", "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω", "LaTeX": "LaTeX", "TeX": "TeX", "textendash": "–", "textemdash": "—"]
        mutating func read(group: Bool = false) -> String {
            guard depth < 64 else { return "" }
            depth += 1; defer { depth -= 1 }
            var result = ""
            while i < chars.count {
                let c = chars[i]; i += 1
                if c == "}" { if group { return result }; continue }
                if c == "{" { result += read(group: true); continue }
                if c == "$" { continue }
                if c == "~" { result += " "; continue }
                if c != "\\" { result.append(c); continue }
                guard i < chars.count else { break }
                let next = chars[i]; i += 1
                var command = String(next)
                if next.isLetter { while i < chars.count, chars[i].isLetter { command.append(chars[i]); i += 1 } }
                if let mark = Self.accents[command] {
                    let base = argument().replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "ȷ", with: "j")
                    if let first = base.first { result += String(first) + mark + base.dropFirst() }
                } else if let symbol = Self.symbols[command] { result += symbol }
                else if command == "href" { _ = argument(); result += argument() }
                else if command == "frac" { result += argument() + "/" + argument() }
                else if command == "\\" || [",", ";", ":", " "].contains(command) { result += " " }
                else if !next.isLetter && command != "!" { result += command }
                // Formatting commands disappear while their following groups remain readable.
            }
            return result
        }
        mutating func argument() -> String {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { return "" }
            if chars[i] == "{" { i += 1; return read(group: true) }
            let c = chars[i]; i += 1; return String(c)
        }
    }
}
extension ReferenceRecord {
    var displayTitle: String { ReferenceText.display(title) }
    var displayAuthors: String { ReferenceText.authors(authors).map(ReferenceText.display).joined(separator: "; ") }
}
