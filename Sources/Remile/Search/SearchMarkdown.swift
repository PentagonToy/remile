import Foundation

struct SearchMarkdown {
    struct Section: Sendable { let number: Int; let line: Int; let title: String; let source: String }
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 8_000_000, let source = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return source
    }
    static func searchText(_ source: String) -> String {
        let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full))
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
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var starts: [(Int, String)] = [], fence: String?
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil else { continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).first?.isWhitespace == true {
                starts.append((index, String(line.dropFirst(hashes)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#")))))
            }
        }
        if starts.first?.0 != 0 { starts.insert((0, "Introduction"), at: 0) }
        var result: [Section] = []
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1].0 : lines.count
            let body = lines[start.0..<end].joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append(Section(number: result.count + 1, line: start.0, title: start.1, source: body))
        }
        return result
    }
}
