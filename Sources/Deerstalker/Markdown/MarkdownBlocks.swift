import Foundation

struct MarkdownBlock: Identifiable {
    enum Style { case paragraph, heading(Int), code, quote, list(String, Int) }
    let id: Int
    var text: AttributedString
    let style: Style

    static func parse(_ source: String) -> [MarkdownBlock] {
        guard let parsed = try? AttributedString(markdown: source) else {
            return [MarkdownBlock(id: 0, text: AttributedString(source), style: .paragraph)]
        }
        var blocks: [MarkdownBlock] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity ?? 0
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if blocks.last?.id == identity {
                blocks[blocks.count - 1].text.append(text)
                continue
            }
            var style: Style = .paragraph
            var ordinal: Int?
            var ordered = false
            var foundListContainer = false
            var depth = 0
            for component in components {
                switch component.kind {
                case .header(let level): style = .heading(level)
                case .codeBlock: style = .code
                case .blockQuote: style = .quote
                case .listItem(let value): if ordinal == nil { ordinal = value }; depth += 1
                case .orderedList:
                    if !foundListContainer { ordered = true; foundListContainer = true }
                case .unorderedList:
                    if !foundListContainer { ordered = false; foundListContainer = true }
                default: break
                }
            }
            if let ordinal { style = .list(ordered ? "\(ordinal)." : "•", depth) }
            blocks.append(MarkdownBlock(id: identity, text: text, style: style))
        }
        return blocks
    }
}
