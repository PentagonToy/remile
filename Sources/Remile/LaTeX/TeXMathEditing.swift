import Foundation

enum TeXMathEditing {
    struct Formula: Equatable, Sendable {
        let start: Int
        let source: String
        let display: Bool
        var highlightOffset: Int? = nil
    }

    private struct Delimiter {
        let end: String
        let start: Int
        let display: Bool
        let environment: String?
    }

    private static let displayEnvironments: Set<String> = [
        "displaymath", "equation", "equation*", "align", "align*", "gather", "gather*"
    ]
    private static let tableEnvironments: Set<String> = ["align", "align*", "gather", "gather*"]
    private static let literalEnvironments: Set<String> = ["verbatim", "verbatim*", "Verbatim", "lstlisting", "minted"]
    private static let tokens = try! NSRegularExpression(
        pattern: #"%[^\r\n]*|\\verb\*?([^a-zA-Z\s])[^\r\n]*?(?:\1|(?=[\r\n]|$))|\\(?:begin|end)\s*\{([A-Za-z*]+)\}|\\(?:text|textnormal|textrm|textsf|texttt|textbf|textit|mbox|label|ref|eqref|cite|url|operatorname)\*?\s*\{|\\(?:[A-Za-z@]+|[^\r\n])|\$\$?|[{}]"#
    )
    private static let numberingCommands = try! NSRegularExpression(
        pattern: #"(?<!\\)((?:\\\\)*)\\(?:label\s*\{[^{}]*\}|(?:notag|nonumber)(?![A-Za-z@]))"#
    )
    private static let maximumPrefix = 512_000
    private static let maximumFormula = 4_096

    static func scriptChange(_ source: String, selection: NSRange, marker: String) -> MarkdownEditing.Change? {
        let text = source as NSString
        let caret = selection.location
        guard marker == "_" || marker == "^", selection.length == 0, caret > 0, caret <= text.length,
              caret == text.length || text.character(at: caret) != 123 else { return nil }
        guard !escaped(text, at: caret),
              scan(text, caret: caret, preview: false) != nil else { return nil }
        return .init(range: selection, text: marker + "{}", selection: NSRange(location: caret + 2, length: 0))
    }

    private static let argumentCommand = try! NSRegularExpression(
        pattern: #"(?<!\\)\\(?:frac|dfrac|tfrac|binom|sqrt|hat|bar|vec|overline|underline|mathbf|mathrm|mathbb)\s*$"#
    )

    static func tabDestination(_ source: String, selection: NSRange) -> Int? {
        let text = source as NSString
        let caret = selection.location
        guard selection.length == 0, caret > 0, caret < text.length, text.character(at: caret) == 125,
              !escaped(text, at: caret), scan(text, caret: caret, preview: false) != nil else { return nil }
        let lowerBound = max(0, caret - maximumFormula)
        guard let opening = openingBrace(in: text, before: caret, lowerBound: lowerBound), opening > 0 else { return nil }
        let preceding = text.character(at: opening - 1)
        if (preceding == 94 || preceding == 95), !escaped(text, at: opening - 1) { return caret + 1 }

        if let command = commandBeforeBrace(in: text, opening: opening, lowerBound: lowerBound) {
            let isTwoPart = ["frac", "dfrac", "tfrac", "binom"].contains(command)
            return isTwoPart && caret + 1 < text.length && text.character(at: caret + 1) == 123 ? caret + 2 : caret + 1
        }
        guard preceding == 125, !escaped(text, at: opening - 1),
              let first = openingBrace(in: text, before: opening - 1, lowerBound: lowerBound),
              let command = commandBeforeBrace(in: text, opening: first, lowerBound: lowerBound),
              ["frac", "dfrac", "tfrac", "binom"].contains(command) else { return nil }
        return caret + 1
    }

    private static func commandBeforeBrace(in text: NSString, opening: Int, lowerBound: Int) -> String? {
        let prefix = text.substring(with: NSRange(location: lowerBound, length: opening - lowerBound))
        guard let match = argumentCommand.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)),
              !escaped(text, at: lowerBound + match.range.location) else { return nil }
        return (prefix as NSString).substring(with: match.range).dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openingBrace(in text: NSString, before end: Int, lowerBound: Int) -> Int? {
        var depth = 0
        for offset in (lowerBound..<end).reversed() {
            let character = text.character(at: offset)
            guard (character == 123 || character == 125), !escaped(text, at: offset) else { continue }
            if character == 125 { depth += 1 }
            else if depth == 0 { return offset }
            else { depth -= 1 }
        }
        return nil
    }

    private static func escaped(_ text: NSString, at offset: Int) -> Bool {
        var start = offset
        while start > 0, text.character(at: start - 1) == 92 { start -= 1 }
        return !(offset - start).isMultiple(of: 2)
    }

    static func formula(_ source: String, selection: NSRange) -> Formula? {
        guard selection.length == 0 else { return nil }
        return scan(source as NSString, caret: selection.location, preview: true)
    }

    private static func scan(_ text: NSString, caret: Int, preview: Bool) -> Formula? {
        guard caret >= 0, caret <= text.length, caret <= maximumPrefix else { return nil }
        var delimiter: Delimiter?
        var literalEnd: String?
        var textGroupDepth = 0
        var end = caret
        var excluded = false
        var comments: [NSRange] = []

        let limit = min(text.length, caret + maximumFormula)
        tokens.enumerateMatches(in: text as String, options: [.withTransparentBounds],
                                range: NSRange(location: 0, length: limit)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let match else { return }
            let range = match.range
            let token = text.substring(with: range)
            let comment = token.hasPrefix("%")
            let literalMarker = match.range(at: 1)
            let verbatim = literalMarker.location != NSNotFound
            let openVerbatim = verbatim && (NSMaxRange(literalMarker) == NSMaxRange(range)
                || text.character(at: literalMarker.location) != text.character(at: NSMaxRange(range) - 1))
            if range.location < caret && (NSMaxRange(range) > caret || ((comment || openVerbatim) && NSMaxRange(range) == caret)) {
                excluded = true
                stop.pointee = true
                return
            }

            let environmentRange = match.range(at: 2)
            let environment = environmentRange.location == NSNotFound ? nil : text.substring(with: environmentRange)
            let beginsEnvironment = token.hasPrefix("\\begin")
            let closesMath = delimiter.map { current in
                if let name = current.environment { return environment == name && !beginsEnvironment }
                return token == current.end
            } ?? false

            if range.location >= caret {
                if !preview || delimiter == nil || literalEnd != nil || textGroupDepth > 0 {
                    stop.pointee = true
                } else if closesMath {
                    end = range.location
                    stop.pointee = true
                } else if comment {
                    comments.append(range)
                }
                return
            }

            if let active = literalEnd {
                if environment == active, !beginsEnvironment { literalEnd = nil }
                return
            }
            if comment {
                if preview, delimiter != nil { comments.append(range) }
                return
            }
            if verbatim { return }

            if textGroupDepth > 0 {
                if token.hasSuffix("{"), token != #"\{"# { textGroupDepth += 1 }
                if token == "}" { textGroupDepth -= 1 }
                return
            }

            if let environment, beginsEnvironment, literalEnvironments.contains(environment) {
                literalEnd = environment
            } else if closesMath {
                delimiter = nil
                comments.removeAll(keepingCapacity: true)
            } else if delimiter != nil, token.hasPrefix("\\"), token.hasSuffix("{"), token != #"\{"# {
                textGroupDepth = 1
            } else if delimiter == nil {
                let start = NSMaxRange(range)
                switch token {
                case "$", "$$":
                    delimiter = Delimiter(end: token, start: start, display: token == "$$", environment: nil)
                case #"\("#:
                    delimiter = Delimiter(end: #"\)"#, start: start, display: false, environment: nil)
                case #"\["#:
                    delimiter = Delimiter(end: #"\]"#, start: start, display: true, environment: nil)
                default:
                    if let environment, beginsEnvironment, displayEnvironments.contains(environment) {
                        delimiter = Delimiter(end: "", start: start, display: true, environment: environment)
                    }
                }
            }
        }
        guard !Task.isCancelled, !excluded, literalEnd == nil, textGroupDepth == 0,
              let delimiter, delimiter.start <= caret else { return nil }
        if !preview { return Formula(start: delimiter.start, source: "", display: delimiter.display) }
        if end == caret {
            while end < limit, text.character(at: end) == 125 { end += 1 }
        }
        guard end - delimiter.start <= maximumFormula else { return nil }
        let source = NSMutableString(string: text.substring(with: NSRange(location: delimiter.start, length: end - delimiter.start)))
        var offset = caret - delimiter.start
        for comment in comments.reversed() where comment.location >= delimiter.start && NSMaxRange(comment) <= end {
            if comment.location < caret { offset -= comment.length }
            source.deleteCharacters(in: NSRange(location: comment.location - delimiter.start, length: comment.length))
        }
        let clean = numberingCommands.stringByReplacingMatches(
            in: source as String, range: NSRange(location: 0, length: source.length), withTemplate: "$1"
        )
        var formula = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formula.isEmpty else { return nil }
        if let environment = delimiter.environment, tableEnvironments.contains(environment) {
            let opener = "\\begin{\(environment)}"
            formula = opener + formula + "\\end{\(environment)}"
            if environment == "align" || environment == "align*" {
                let prefix = (source as NSString).substring(to: offset)
                let cleanPrefix = numberingCommands.stringByReplacingMatches(
                    in: prefix, range: NSRange(location: 0, length: offset), withTemplate: "$1"
                )
                let leading = clean.prefix(while: \.isWhitespace).count
                let position = max(0, min(cleanPrefix.count - leading, clean.trimmingCharacters(in: .whitespacesAndNewlines).count))
                return Formula(start: delimiter.start, source: formula, display: true, highlightOffset: opener.count + position)
            }
        }
        return Formula(start: delimiter.start, source: formula, display: delimiter.display)
    }
}
