import Foundation

/// Bounded, source-preserving table operations shared by native editing and the CLI.
struct MarkdownTable {
    var cells: [[String]]
    var range: NSRange
    var alignments: [String] = []
    var columns: Int { cells.map(\.count).max() ?? 2 }
    static func empty(at range: NSRange) -> Self { Self(cells: [["Heading", "Heading"], ["", ""]], range: range) }
    var markdown: String {
        let count = max(1, columns)
        func row(_ values: [String]) -> String { "| " + (0..<count).map { index in
            (index < values.count ? values[index] : "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
        }.joined(separator: " | ") + " |" }
        guard let header = cells.first else { return "" }
        return ([row(header), "| " + (0..<count).map { $0 < alignments.count ? alignments[$0] : "---" }.joined(separator: " | ") + " |"] + cells.dropFirst().map(row)).joined(separator: "\n")
    }
    static func parse(_ source: String, selection: NSRange) -> Self? {
        let raw = source as NSString
        guard selection.location <= raw.length else { return nil }
        var start = raw.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var end = NSMaxRange(raw.lineRange(for: NSRange(location: selection.location, length: 0)))
        func isRow(_ range: NSRange) -> Bool { raw.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("|") }
        guard isRow(NSRange(location: start, length: end - start)) else { return nil }
        while start > 0 { let line = raw.lineRange(for: NSRange(location: start - 1, length: 0)); guard isRow(line) else { break }; start = line.location }
        while end < raw.length { let line = raw.lineRange(for: NSRange(location: end, length: 0)); guard isRow(line) else { break }; end = NSMaxRange(line) }
        let text = raw.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .newlines)
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2, lines.count <= 101 else { return nil }
        func split(_ line: String) -> [String] {
            var values: [String] = [], cell = "", escaped = false, code = false
            for character in line.trimmingCharacters(in: .whitespaces).dropFirst() {
                if escaped { if character != "|" { cell.append("\\") }; cell.append(character); escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "`" { code.toggle(); cell.append(character) }
                else if character == "|", !code { values.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
                else { cell.append(character) }
            }
            if escaped { cell.append("\\") }
            if !cell.trimmingCharacters(in: .whitespaces).isEmpty { values.append(cell.trimmingCharacters(in: .whitespaces)) }
            return values
        }
        let separator = split(lines[1])
        guard !separator.isEmpty, separator.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        let cells = [split(lines[0])] + lines.dropFirst(2).map(split)
        guard cells.allSatisfy({ $0.count == separator.count }), separator.count <= 12 else { return nil }
        return Self(cells: cells, range: NSRange(location: start, length: (text as NSString).length), alignments: separator)
    }
    static func pasted(_ text: String) -> String? {
        guard text.utf8.count <= 100_000, text.contains("\t") else { return nil }
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"", quoted, index + 1 < characters.count, characters[index + 1] == "\"" { cell.append("\""); index += 2; continue }
            if character == "\"", quoted || cell.isEmpty { quoted.toggle() }
            else if character == "\t", !quoted { row.append(cell); cell = "" }
            else if character == "\n", !quoted { row.append(cell); rows.append(row); row = []; cell = "" }
            else { cell.append(character) }
            index += 1
            if rows.count > 100 || row.count > 12 { return nil }
        }
        guard !quoted else { return nil }
        if !row.isEmpty || !cell.isEmpty { row.append(cell); rows.append(row) }
        guard (2...100).contains(rows.count), let count = rows.first?.count, (2...12).contains(count), rows.allSatisfy({ $0.count == count }) else { return nil }
        return Self(cells: rows, range: .init()).markdown
    }
}
