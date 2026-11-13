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
    static func parse(_ source: String, selection: NSRange, maximumLength: Int = .max) -> Self? {
        let raw = source as NSString
        guard selection.location <= raw.length else { return nil }
        var start = raw.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var end = NSMaxRange(raw.lineRange(for: NSRange(location: selection.location, length: 0)))
        var rowCount = 1
        func isRow(_ range: NSRange) -> Bool {
            var offset = range.location
            while offset < NSMaxRange(range) {
                switch raw.character(at: offset) {
                case 32, 9: offset += 1
                case 124: return true
                default: return false
                }
            }
            return false
        }
        guard isRow(NSRange(location: start, length: end - start)) else { return nil }
        guard end - start <= maximumLength else { return nil }
        while start > 0 {
            let line = raw.lineRange(for: NSRange(location: start - 1, length: 0))
            guard isRow(line) else { break }
            rowCount += 1
            guard rowCount <= 101, end - line.location <= maximumLength else { return nil }
            start = line.location
        }
        while end < raw.length {
            let line = raw.lineRange(for: NSRange(location: end, length: 0))
            guard isRow(line) else { break }
            rowCount += 1
            guard rowCount <= 101, NSMaxRange(line) - start <= maximumLength else { return nil }
            end = NSMaxRange(line)
        }
        let text = raw.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .newlines)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
    enum Navigation { case next, previous, nextRow }

    static func navigate(_ source: String, selection: NSRange, action: Navigation) -> MarkdownEditing.Change? {
        let text = source as NSString
        guard selection.location <= text.length,
              let table = parse(source, selection: selection, maximumLength: 65_536),
              table.range.location <= 512_000 else { return nil }
        let columns = table.columns
        var fence: (Character, Int)?
        let preceding = text.substring(to: table.range.location)
        for line in preceding.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: { $0 == " " })
            guard line.count - trimmed.count <= 3, let marker = trimmed.first, marker == "\u{60}" || marker == "~" else { continue }
            let count = trimmed.prefix(while: { $0 == marker }).count
            guard count >= 3 else { continue }
            if let active = fence {
                if marker == active.0, count >= active.1, trimmed.dropFirst(count).allSatisfy(\.isWhitespace) { fence = nil }
            } else {
                fence = (marker, count)
            }
        }
        guard fence == nil else { return nil }

        var rows: [[NSRange]] = []
        var start = table.range.location
        var lineNumber = 0
        while start < NSMaxRange(table.range) {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            if lineNumber != 1 {
                let ranges = cellRanges(in: text, start: start, end: contentsEnd)
                guard ranges.count == columns else { return nil }
                rows.append(ranges)
            }
            lineNumber += 1
            start = end
        }
        for (row, cells) in rows.enumerated() {
            guard let column = cells.firstIndex(where: {
                selection.location >= $0.location && NSMaxRange(selection) <= NSMaxRange($0)
            }) else { continue }
            switch action {
            case .next:
                if column + 1 < cells.count { return move(to: cells[column + 1], in: text) }
                if row + 1 < rows.count { return move(to: rows[row + 1][0], in: text) }
            case .previous:
                if column > 0 { return move(to: cells[column - 1], in: text) }
                if row > 0, let previous = rows[row - 1].last { return move(to: previous, in: text) }
            case .nextRow:
                if row + 1 < rows.count { return move(to: rows[row + 1][column], in: text) }
                guard rows.count < 100 else { return nil }
                let newline = text.substring(with: table.range).contains("\r\n") ? "\r\n" : "\n"
                let insertion = newline + "|" + String(repeating: "   |", count: columns)
                let location = NSMaxRange(table.range)
                return .init(range: NSRange(location: location, length: 0), text: insertion,
                             selection: NSRange(location: location + newline.utf16.count + 2 + 4 * column, length: 0))
            }
            return nil
        }
        return nil
    }

    private static func move(to cell: NSRange, in text: NSString) -> MarkdownEditing.Change {
        let padded = cell.length > 0 && text.character(at: cell.location) == 32
        let caret = NSRange(location: cell.location + (padded ? 1 : 0), length: 0)
        return .init(range: caret, text: "", selection: caret)
    }

    private static func cellRanges(in text: NSString, start: Int, end: Int) -> [NSRange] {
        var separators: [Int] = []
        var cursor = start
        var codeRun = 0
        while cursor < end {
            switch text.character(at: cursor) {
            case 92 where codeRun == 0:
                cursor += 2
                continue
            case 96:
                let opening = cursor
                while cursor < end, text.character(at: cursor) == 96 { cursor += 1 }
                let count = cursor - opening
                if codeRun == 0 { codeRun = count }
                else if codeRun == count { codeRun = 0 }
                continue
            case 124 where codeRun == 0:
                separators.append(cursor)
            default:
                break
            }
            cursor += 1
        }
        guard let last = separators.last else { return [] }
        if !text.substring(with: NSRange(location: last + 1, length: end - last - 1))
            .trimmingCharacters(in: .whitespaces).isEmpty { separators.append(end) }
        return zip(separators, separators.dropFirst()).map {
            NSRange(location: $0 + 1, length: $1 - $0 - 1)
        }
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
