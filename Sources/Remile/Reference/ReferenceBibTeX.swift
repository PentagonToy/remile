import Foundation

/// A bounded BibTeX reader. Unsupported expressions fail without importing a partial bibliography.
enum ReferenceBibTeX {
    static func parse(_ source: String) throws -> [ReferenceRecord] {
        guard source.utf8.count <= 4_000_000 else { throw ReferenceFailure("Use a bibliography smaller than 4 MB.") }
        var reader = Parser(source)
        return try reader.read()
    }
    static func export(_ records: [ReferenceRecord]) throws -> String {
        var keys: Set<String> = []
        return try records.map { record in
            guard validToken(record.citationKey), validToken(record.type), keys.insert(record.citationKey).inserted else { throw ReferenceFailure("Use a unique citation key for each reference before exporting.") }
            let rows = try record.fields.sorted { $0.key < $1.key }.filter { !$0.value.isEmpty }.map { name, value in
                guard validToken(name), balanced(value) else { throw ReferenceFailure("Check the braces in \(record.title).") }
                return "  \(name) = {\(value)}"
            }
            return "@\(record.type){\(record.citationKey),\n" + rows.joined(separator: ",\n") + "\n}"
        }.joined(separator: "\n\n") + (records.isEmpty ? "" : "\n")
    }
    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_:-./+".unicodeScalars.contains($0) }
    }
    private static func balanced(_ source: String) -> Bool {
        var depth = 0, escaped = false
        for c in source {
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0 && !escaped
    }
    private struct Parser {
        var chars: [Character]
        var index = 0
        var macros: [String: String] = Dictionary(uniqueKeysWithValues: ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].map { ($0, $0.capitalized) })
        init(_ source: String) { chars = Array(source) }
        var current: Character? { index < chars.count ? chars[index] : nil }
        mutating func skip() {
            while let c = current {
                if c.isWhitespace { index += 1 }
                else if c == "%" { while let c = current, c != "\n" { index += 1 } }
                else { break }
            }
        }
        mutating func expect(_ c: Character) throws {
            skip(); guard current == c else { throw ReferenceFailure("Check the BibTeX near character \(index + 1).") }; index += 1
        }
        mutating func token() -> String {
            let start = index
            while let c = current, !c.isWhitespace, !["{", "}", "(", ")", ",", "=", "#", "\"", "%"].contains(c) { index += 1 }
            return String(chars[start..<index])
        }
        mutating func group(_ opening: Character) throws -> String {
            try expect(opening)
            let closing: Character = opening == "(" ? ")" : "}"
            let start = index; var depth = 1, escaped = false
            while let c = current {
                index += 1
                if escaped { escaped = false; continue }
                if c == "\\" { escaped = true; continue }
                if c == opening { depth += 1 }
                if c == closing { depth -= 1; if depth == 0 { return String(chars[start..<(index - 1)]) } }
            }
            throw ReferenceFailure("A BibTeX group is not closed.")
        }
        mutating func atom() throws -> String {
            skip()
            if current == "{" { return try group("{") }
            if current == "\"" {
                index += 1; let start = index; var depth = 0, escaped = false
                while let c = current {
                    index += 1
                    if escaped { escaped = false; continue }
                    if c == "\\" { escaped = true; continue }
                    if c == "{" { depth += 1 }
                    if c == "}" { depth -= 1 }
                    if c == "\"", depth == 0 { return String(chars[start..<(index - 1)]) }
                    guard depth >= 0 else { throw ReferenceFailure("Check the braces in a quoted field.") }
                }
                throw ReferenceFailure("A quoted BibTeX field is not closed.")
            }
            let value = token()
            guard !value.isEmpty else { throw ReferenceFailure("A BibTeX field is empty.") }
            if value.allSatisfy(\.isNumber) { return value }
            guard let expanded = macros[value.lowercased()] else { throw ReferenceFailure("Define the BibTeX string \(value), or put the value in braces.") }
            return expanded
        }
        mutating func value() throws -> String {
            var result = try atom(); skip()
            while current == "#" { index += 1; result += try atom(); skip() }
            return result
        }
        mutating func read() throws -> [ReferenceRecord] {
            var records: [ReferenceRecord] = [], keys: Set<String> = []
            while true {
                skip(); guard current != nil else { break }
                guard current == "@" else { throw ReferenceFailure("Paste BibTeX entries beginning with @, or add the reference manually.") }
                let start = index; index += 1
                let type = token().lowercased(); skip()
                guard let opening = current, opening == "{" || opening == "(" else { throw ReferenceFailure("A BibTeX entry needs braces.") }
                if type == "comment" { _ = try group(opening); continue }
                index += 1
                let closing: Character = opening == "{" ? "}" : ")"
                if type == "preamble" { _ = try value(); skip(); if current == "," { index += 1 }; try expect(closing); continue }
                if type == "string" {
                    skip(); let name = token().lowercased(); try expect("="); macros[name] = try value(); skip(); if current == "," { index += 1 }; try expect(closing); continue
                }
                skip(); let key = token(); skip()
                guard ReferenceBibTeX.validToken(type), ReferenceBibTeX.validToken(key), keys.insert(key).inserted else { throw ReferenceFailure("Use valid, unique BibTeX citation keys.") }
                var record = ReferenceRecord(); record.key = key; record.type = type
                if current == "," { index += 1 } else if current != closing { throw ReferenceFailure("Add a comma after the citation key.") }
                while true {
                    skip(); if current == closing { index += 1; break }
                    let field = token().lowercased()
                    guard ReferenceBibTeX.validToken(field), record.fields[field] == nil else { throw ReferenceFailure("Use valid, unique field names.") }
                    try expect("="); record.fields[field] = try value(); skip()
                    if current == "," { index += 1 } else if current != closing { throw ReferenceFailure("Add a comma between BibTeX fields.") }
                }
                record.originalCitation = String(chars[start..<index]); records.append(record)
                guard records.count <= 10_000 else { throw ReferenceFailure("Import at most 10,000 references at once.") }
            }
            guard !records.isEmpty else { throw ReferenceFailure("No BibTeX references were found.") }
            return records
        }
    }
}
