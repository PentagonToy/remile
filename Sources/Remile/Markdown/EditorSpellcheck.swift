import Foundation

/// Keep the system spelling service on prose; syntax, identifiers and formulae are not words.
enum EditorSpellcheck {
    private static let patterns = [
        #"(?m)^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[^\n]*(?:\n|$)"#,
        #"`+[^`\n]*`+"#,
        #"(?s)\\begin\{(align\*?|aligned|equation\*?|gather\*?|cases|matrix|pmatrix|bmatrix)\}.*?(?:\\end\{\1\}|\z)"#,
        #"(?s)(?<!\\)\$\$.*?(?<!\\)\$\$|(?<!\\)\$[^$\n]+(?<!\\)\$|\\\[.*?\\\]|\\\(.*?\\\)"#,
        #"\\(?:begin|end|label|ref|eqref|cite\w*|input|include|includegraphics|bibliography|bibliographystyle|usepackage|documentclass|addbibresource)(?:\[[^\]\n]*\])?\{[^}\n]*\}"#,
        #"\\[A-Za-z@]+\*?"#,
        #"https?://[^\s<>]+|\]\([^\s)]*\)|<!--[^>]*-->"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    static func excluded(_ source: String) -> [NSRange] {
        let range = NSRange(location: 0, length: (source as NSString).length)
        return patterns.flatMap { $0.matches(in: source, range: range).map(\.range) }
    }
    static func sentenceOpenings(_ source: String) -> [NSRange] {
        let excluded = excluded(source), raw = source as NSString
        let patterns = [#"(?:\A|\n[ \t]*\n)[ \t]*([a-z][A-Za-z']*)\b"#, #"[.!?][ \t]*\n[ \t]*([a-z][A-Za-z']*)\b"#]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }.flatMap { $0.matches(in: source, range: NSRange(location: 0, length: raw.length)).map { $0.range(at: 1) } }.filter { accepts($0, excluded: excluded) }
    }
    static func accepts(_ range: NSRange, excluded: [NSRange]) -> Bool { !excluded.contains { NSIntersectionRange(range, $0).length > 0 } }
}
