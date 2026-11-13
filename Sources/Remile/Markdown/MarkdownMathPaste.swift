import Foundation

/// Normalise explicit TeX delimiters inside a paste, using the surrounding Markdown for context.
enum MarkdownMathPaste {
    private static let tokens = try! NSRegularExpression(
        pattern: #"(?m)^(?:(?:[ \t]*>)+[ \t]?)?([ \t]*)(\x60{3,}|~{3,})([^\r\n]*)|^(?: {4}| {0,3}\t)[^\r\n]*|\x5c[\x5c()\x5b\x5d\x60$]|\x60+|\${1,2}|\r\n?|\n"#
    )
    private static let tick = Character(UnicodeScalar(96))

    static func normalised(_ text: String, in document: String = "", replacing selection: NSRange = .init()) -> String? {
        guard text.contains(#"\("#) || text.contains(#"\["#) else { return nil }
        let source = (document as NSString).replacingCharacters(in: selection, with: text)
        let characters = source as NSString
        let pasted = NSRange(location: selection.location, length: text.utf16.count)
        var fence: String?
        var codeWidth: Int?
        var dollar: String?
        var opener: (token: String, range: NSRange)?
        var edits: [(NSRange, String)] = []
        let scan = NSRange(location: 0, length: NSMaxRange(pasted))
        tokens.enumerateMatches(in: source, options: [.withTransparentBounds, .withoutAnchoringBounds], range: scan) { match, _, _ in
            guard let match else { return }
            let range = match.range
            if match.range(at: 2).location != NSNotFound {
                let marker = characters.substring(with: match.range(at: 2))
                let indent = characters.substring(with: match.range(at: 1))
                let tail = characters.substring(with: match.range(at: 3))
                if let current = fence {
                    if marker.hasPrefix(current), tail.allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
                } else if indent.count < 4 && !indent.contains("\t"),
                          marker.hasPrefix("~") || !tail.contains(tick) {
                    fence = marker
                }
                codeWidth = nil
                dollar = nil
                opener = nil
                return
            }
            guard fence == nil else { return }
            let token = characters.substring(with: range)
            if token == "\n" || token == "\r" || token == "\r\n" {
                if dollar == "$" { dollar = nil }
                if opener?.token == #"\("# { opener = nil }
                return
            }
            if token.hasPrefix(" ") || token.hasPrefix("\t") {
                if opener?.token != #"\["# { opener = nil }
                return
            }
            if token.first == tick, dollar == nil {
                if codeWidth == nil { codeWidth = token.count }
                else if codeWidth == token.count { codeWidth = nil }
                opener = nil
                return
            }
            guard codeWidth == nil else { return }
            if token == "$" || token == "$$" {
                if dollar == token { dollar = nil }
                else if dollar == nil, token == "$$" || canOpenInlineMath(at: NSMaxRange(range), in: characters) {
                    dollar = token
                }
                opener = nil
                return
            }
            guard dollar == nil else { return }
            switch token {
            case #"\("#, #"\["#:
                opener = (token, range)
            case #"\)"#, #"\]"#:
                guard let start = opener else { return }
                opener = nil
                let display = start.token == #"\["#
                guard display == (token == #"\]"#),
                      start.range.location >= pasted.location, NSMaxRange(range) <= NSMaxRange(pasted),
                      NSMaxRange(start.range) < range.location else { return }
                if display {
                    let before = characters.lineRange(for: start.range).location
                    let prefix = characters.substring(with: NSRange(location: before, length: start.range.location - before))
                    let after = NSMaxRange(range)
                    let lineEnd = NSMaxRange(characters.lineRange(for: range))
                    let suffix = characters.substring(with: NSRange(location: after, length: lineEnd - after))
                    let needsLeadingBreak = !prefix.allSatisfy { $0 == " " || $0 == "\t" || $0 == ">" }
                    let needsTrailingBreak = !suffix.allSatisfy(\.isWhitespace) && !prefix.contains(">")
                    edits.append((start.range, needsLeadingBreak ? "\n$$" : "$$"))
                    edits.append((range, needsTrailingBreak ? "$$\n" : "$$"))
                } else {
                    edits.append((start.range, "$"))
                    edits.append((range, "$"))
                }
            default: break
            }
        }
        guard !edits.isEmpty else { return nil }
        var result = ""
        var offset = pasted.location
        for (range, replacement) in edits {
            result += characters.substring(with: NSRange(location: offset, length: range.location - offset))
            result += replacement
            offset = NSMaxRange(range)
        }
        result += characters.substring(with: NSRange(location: offset, length: NSMaxRange(pasted) - offset))
        return result
    }

    private static func canOpenInlineMath(at index: Int, in text: NSString) -> Bool {
        guard index < text.length, text.character(at: index) > 32 else { return false }
        if !(48...57).contains(text.character(at: index)) { return true }
        let end = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
        return text.range(of: "$", range: NSRange(location: index, length: end - index)).location != NSNotFound
    }
}
