import AppKit

/// Editor-only palettes derived from the three brand colours.
enum TeXEditorTheme: String, CaseIterable {
    case remile = "remile.", paper = "Paper", graphite = "Graphite", parchment = "Parchment", contrast = "High Contrast"
    struct Palette { let background: NSColor; let ink: NSColor; let command: NSColor; let comment: NSColor; let punctuation: NSColor }
    var palette: Palette {
        let slate = RemileStyle.slate, paper = RemileStyle.ivory, brick = RemileStyle.gold
        func mix(_ a: NSColor, _ b: NSColor, _ fraction: CGFloat) -> NSColor { a.blended(withFraction: fraction, of: b)! }
        switch self {
        case .remile: return Palette(background: slate, ink: paper, command: NSColor(red: 0.62, green: 0.75, blue: 0.96, alpha: 1), comment: RemileStyle.sage, punctuation: RemileStyle.amber)
        case .paper: return Palette(background: mix(paper, .white, 0.5), ink: slate, command: brick, comment: mix(slate, paper, 0.35), punctuation: mix(brick, slate, 0.4))
        case .graphite: return Palette(background: mix(slate, .black, 0.3), ink: mix(paper, .white, 0.25), command: mix(brick, paper, 0.65), comment: mix(slate, paper, 0.6), punctuation: mix(brick, paper, 0.4))
        case .parchment: return Palette(background: paper, ink: slate, command: brick, comment: mix(slate, paper, 0.3), punctuation: mix(brick, slate, 0.5))
        case .contrast: return Palette(background: mix(slate, .black, 0.65), ink: paper, command: mix(brick, paper, 0.7), comment: mix(slate, paper, 0.7), punctuation: mix(paper, .white, 0.5))
        }
    }
}

enum TeXSyntax {
    enum Kind { case command, punctuation, comment }
    struct Token { let range: NSRange; let kind: Kind }
    private static let rules: [(NSRegularExpression, Kind)] = [
        (#"\\(?:[a-zA-Z@]+|[^a-zA-Z\s])"#, .command),
        (#"[{}\[\]$&_^]"#, .punctuation),
        (#"(?m)(?<!\\)(?:\\\\)*(%[^\n]*)"#, .comment)
    ].compactMap { pattern, kind in (try? NSRegularExpression(pattern: pattern)).map { ($0, kind) } }
    static func tokens(_ source: String, range: NSRange) -> [Token] {
        rules.flatMap { regex, kind in regex.matches(in: source, range: range).map { Token(range: kind == .comment ? $0.range(at: 1) : $0.range, kind: kind) } }
    }
}
