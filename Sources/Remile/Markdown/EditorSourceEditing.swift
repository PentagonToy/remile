import Foundation

enum EditorSourceEditing {
    static func indent(_ source: String, selection: NSRange, reverse: Bool) -> MarkdownEditing.Change? {
        let text = source as NSString
        guard selection.location <= text.length, NSMaxRange(selection) <= text.length else { return nil }
        if selection.length == 0 && !reverse {
            return .init(range: selection, text: "    ", selection: NSRange(location: selection.location + 4, length: 0))
        }
        let range = text.lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - 1)))
        let lines = text.substring(with: range).components(separatedBy: "\n")
        let replacement = lines.enumerated().map { i, line -> String in
            guard !(i == lines.count - 1 && line.isEmpty) else { return line }
            if !reverse { return "    " + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(line.prefix(4).prefix(while: { $0 == " " }).count))
        }.joined(separator: "\n")
        return .init(range: range, text: replacement, selection: NSRange(location: range.location, length: selection.length == 0 ? 0 : (replacement as NSString).length))
    }
    static func toggleComment(_ source: String, selection: NSRange) -> MarkdownEditing.Change? {
        let text = source as NSString
        guard selection.location <= text.length, NSMaxRange(selection) <= text.length else { return nil }
        let range = text.lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - 1)))
        let lines = text.substring(with: range).components(separatedBy: "\n")
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let uncomment = !nonempty.isEmpty && nonempty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }
        let replacement = lines.enumerated().map { i, line -> String in
            if i == lines.count - 1 && line.isEmpty { return line }
            let prefix = String(line.prefix(while: { $0 == " " || $0 == "\t" })), rest = String(line.dropFirst(prefix.count))
            if uncomment { return prefix + (rest.hasPrefix("% ") ? String(rest.dropFirst(2)) : rest.hasPrefix("%") ? String(rest.dropFirst()) : rest) }
            return prefix + "% " + rest
        }.joined(separator: "\n")
        return .init(range: range, text: replacement, selection: NSRange(location: range.location, length: (replacement as NSString).length))
    }
}
