import Foundation

struct SearchMarkdown {
    struct Section: Sendable { let number: Int; let line: Int; let title: String; let source: String }
    struct Heading: Sendable, Equatable { let number: Int; let line: Int; let title: String }
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 8_000_000, let source = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return source
    }
    static func searchText(_ source: String) -> String {
        let parsed = try? AttributedString(markdown: source.replacingOccurrences(of: "\n", with: "  \n"), options: .init(interpretedSyntax: .full))
        guard let parsed else { return source }
        var result = "", previous: Int?
        for run in parsed.runs {
            let block = run.presentationIntent?.components.first?.identity ?? 0
            if previous != nil && previous != block { result += "\n" }
            result += String(parsed[run.range].characters); previous = block
        }
        return result
    }
    /// Source headings are stable navigation anchors, not invented PDF pages.
    static func sections(_ source: String) -> [Section] {
        let lines = lines(in: source)
        let headings = headings(in: lines)
        return headings.enumerated().map { index, heading in
            let end = index + 1 < headings.count ? headings[index + 1].line : lines.count
            let body = lines[heading.line..<end].joined(separator: "\n")
            return Section(number: heading.number, line: heading.line, title: heading.title, source: body)
        }
    }
    static func headings(_ source: String) -> [Heading] { headings(in: lines(in: source)) }

    private static func lines(in source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func headings(in lines: [String]) -> [Heading] {
        var starts: [(Int, String)] = [], fence: String?
        var hasIntroduction = false
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let hashes = line.prefix(while: { $0 == "#" }).count
            let isHeading = fence == nil && (1...6).contains(hashes) && line.dropFirst(hashes).first?.isWhitespace == true
            if starts.isEmpty, !hasIntroduction, !isHeading {
                hasIntroduction = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            if isHeading {
                starts.append((index, String(line.dropFirst(hashes)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#")))))
            }
        }
        if hasIntroduction, starts.first?.0 != 0 { starts.insert((0, "Introduction"), at: 0) }
        return starts.enumerated().map { index, start in
            Heading(number: index + 1, line: start.0, title: start.1)
        }
    }
}
