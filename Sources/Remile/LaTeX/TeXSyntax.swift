import AppKit

/// The default follows the app appearance. Paper stays softly white.
enum TeXEditorTheme: String, CaseIterable {
    case remile = "remile.", paper = "Paper"
    var title: String { self == .remile ? "Default" : "Paper" }
    struct Palette { let background: NSColor; let ink: NSColor; let command: NSColor; let comment: NSColor; let punctuation: NSColor }
    var palette: Palette {
        let light = Palette(background: RemileStyle.paper, ink: RemileStyle.slate,
                            command: NSColor(srgbRed: 0.20, green: 0.35, blue: 0.58, alpha: 1),
                            comment: NSColor(srgbRed: 0.29, green: 0.45, blue: 0.36, alpha: 1), punctuation: RemileStyle.gold)
        if self == .paper { return Palette(background: RemileStyle.paper.blended(withFraction: 0.7, of: .white)!, ink: light.ink, command: light.command, comment: light.comment, punctuation: light.punctuation) }
        let dark = Palette(background: RemileStyle.slate, ink: RemileStyle.ivory,
                           command: NSColor(srgbRed: 0.62, green: 0.75, blue: 0.96, alpha: 1),
                           comment: RemileStyle.sage, punctuation: RemileStyle.amber)
        func adaptive(_ key: KeyPath<Palette, NSColor>) -> NSColor {
            NSColor(name: nil) { appearance in (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)[keyPath: key] }
        }
        return Palette(background: adaptive(\.background), ink: adaptive(\.ink), command: adaptive(\.command), comment: adaptive(\.comment), punctuation: adaptive(\.punctuation))
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
