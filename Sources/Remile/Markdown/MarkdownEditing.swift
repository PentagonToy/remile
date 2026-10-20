import Foundation

/// UTF-16 ranges match AppKit selection and undo coordinates, including emoji.
enum MarkdownEditing {
    struct Change { let range: NSRange; let text: String; let selection: NSRange }
    static func wrap(_ source: String, selection: NSRange, before: String, after: String) -> Change {
        let value = source as NSString
        let range = NSIntersectionRange(selection, NSRange(location: 0, length: value.length))
        let selected = value.substring(with: range)
        return Change(range: range, text: before + selected + after, selection: NSRange(location: range.location + (before as NSString).length, length: range.length))
    }
    static func prefix(_ source: String, selection: NSRange, marker: String) -> Change {
        let value = source as NSString
        let safe = NSIntersectionRange(selection, NSRange(location: 0, length: value.length))
        let covered = NSRange(location: safe.location, length: max(0, safe.length - 1))
        let range = value.lineRange(for: covered)
        let lines = value.substring(with: range).components(separatedBy: "\n")
        let changed = lines.enumerated().map { index, line in index == lines.count - 1 && line.isEmpty ? line : marker + line }.joined(separator: "\n")
        return Change(range: range, text: changed, selection: NSRange(location: range.location, length: (changed as NSString).length))
    }
    static func pair(_ source: String, range: NSRange, replacement: String) -> Change? {
        let text = source as NSString
        guard replacement.count == 1, range.location <= text.length, NSMaxRange(range) <= text.length else { return nil }
        let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`", "$": "$"]
        let next = range.location < text.length ? text.substring(with: NSRange(location: range.location, length: 1)) : ""
        if range.length == 0, replacement == next, pairs.values.contains(replacement) {
            if replacement == "$", range.location > 0, text.substring(with: NSRange(location: range.location - 1, length: 1)) == "$" {
                return Change(range: NSRange(location: range.location - 1, length: 2), text: "$$\n\n$$", selection: NSRange(location: range.location + 2, length: 0))
            }
            return Change(range: range, text: "", selection: NSRange(location: range.location + 1, length: 0))
        }
        guard let closing = pairs[replacement] else { return nil }
        if range.length > 0 { return wrap(source, selection: range, before: replacement, after: closing) }
        guard next.isEmpty || next.first?.isWhitespace == true || [")", "]", "}"].contains(next) else { return nil }
        return Change(range: range, text: replacement + closing, selection: NSRange(location: range.location + 1, length: 0))
    }
    static func newline(_ source: String, selection: NSRange) -> Change? {
        let value = source as NSString
        guard selection.length == 0, selection.location <= value.length else { return nil }
        let line = value.lineRange(for: selection)
        let prefix = value.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        if let expression = try? NSRegularExpression(pattern: #"^\s*\\begin\{([A-Za-z*]+)\}\s*$"#),
           let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) {
            let name = (prefix as NSString).substring(with: match.range(at: 1))
            let end = "\\end{\(name)}"
            if !value.substring(from: selection.location).prefix(1000).contains(end) {
                return Change(range: selection, text: "\n    \n" + end, selection: NSRange(location: selection.location + 5, length: 0))
            }
        }
        guard let regex = try? NSRegularExpression(pattern: "^(\\s*)(?:(- \\[)[ xX](\\] )|([-+*] )|([0-9]+)([.)] )|(> ))(.*)$"),
              let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { return nil }
        let raw = prefix as NSString
        func group(_ number: Int) -> String { let r = match.range(at: number); return r.location == NSNotFound ? "" : raw.substring(with: r) }
        let remainder = value.substring(with: NSRange(location: selection.location, length: NSMaxRange(line) - selection.location))
        if group(8).trimmingCharacters(in: .whitespaces).isEmpty && remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let range = NSRange(location: line.location, length: selection.location - line.location)
            return Change(range: range, text: "", selection: NSRange(location: line.location, length: 0))
        }
        let marker: String
        if !group(2).isEmpty { marker = "- [ ] " }
        else if !group(5).isEmpty {
            guard let number = Int(group(5)), number < Int.max else { return nil }
            marker = "\(number + 1)" + group(6)
        }
        else { marker = group(4).isEmpty ? group(7) : group(4) }
        let text = "\n" + group(1) + marker
        return Change(range: selection, text: text, selection: NSRange(location: selection.location + (text as NSString).length, length: 0))
    }
}
