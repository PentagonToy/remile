import Foundation

/// A lazy, bounded project index. Parsing runs on this actor rather than on the UI thread.
actor TeXLocalCompletion {
    private struct Entry {
        let source: String
        let labels: [String]
        let commands: [EditorCompletion.Item]
        let environments: [String]
    }
    private var entries: [String: Entry] = [:]
    private(set) var preparations = 0
    static let sourceBudget = 2_000_000
    static let fileBudget = 256_000
    private static let arguments = try! NSRegularExpression(pattern: #"(?<!\\)\\(includegraphics|input|include|ref|eqref|autoref|pageref|cref|Cref|nameref|usepackage|RequirePackage|documentclass|bibliography|addbibresource|begin|end)(?:\[[^\]\n]*\])?\{([^{}\n]*)$"#)
    private static let comments = try! NSRegularExpression(pattern: #"(?m)((?<!\\)(?:\\\\)*)%[^\r\n]*"#)
    private static let labelPattern = try! NSRegularExpression(pattern: #"\\label\{([^{}\n]+)\}"#)
    private static let commandPattern = try! NSRegularExpression(pattern: #"\\(?:newcommand|renewcommand|providecommand|DeclareRobustCommand)\*?\s*(?:\{\\([A-Za-z@]+)\}|\\([A-Za-z@]+))\s*(?:\[([0-9])\])?(?:\[([^\]\n]*)\])?"#)
    private static let operatorPattern = try! NSRegularExpression(pattern: #"\\DeclareMathOperator\*?\s*\{\\([A-Za-z@]+)\}"#)
    private static let environmentPattern = try! NSRegularExpression(pattern: #"\\(?:newenvironment|renewenvironment)\*?\s*\{([A-Za-z@*]+)\}"#)
    private static let packages = ["amsmath", "amssymb", "amsthm", "mathtools", "graphicx", "hyperref", "cleveref", "geometry", "fontenc", "inputenc", "babel", "polyglossia", "fontspec", "unicode-math", "biblatex", "natbib", "booktabs", "array", "tabularx", "longtable", "siunitx", "xcolor", "tikz", "pgfplots", "subcaption", "caption", "float", "enumitem", "microtype", "listings", "minted", "url", "csquotes", "setspace"]
    private static let classes = ["article", "report", "book", "letter", "beamer", "memoir", "scrartcl", "scrreprt", "scrbook", "standalone"]

    func context(_ source: String, selection: NSRange, file: String, paths: [String], buffers: [String: String]) -> EditorCompletion.Context? {
        let text = source as NSString
        guard selection.length == 0, selection.location <= text.length, !Task.isCancelled else { return nil }
        let start = max(0, selection.location - 300)
        let raw = text.substring(with: NSRange(location: start, length: selection.location - start)) as NSString
        let suffix = Self.comments.stringByReplacingMatches(in: raw as String, range: NSRange(location: 0, length: raw.length), withTemplate: "$1") as NSString
        // A removed comment at the cursor must not become an earlier command context.
        guard suffix.length == raw.length else { return nil }
        if let match = Self.arguments.firstMatch(in: suffix as String, range: NSRange(location: 0, length: suffix.length)) {
            let command = suffix.substring(with: match.range(at: 1)), argument = suffix.substring(with: match.range(at: 2))
            let list = ["usepackage", "RequirePackage", "bibliography", "cref", "Cref"].contains(command)
            let prefix = list ? String(argument.split(separator: ",", omittingEmptySubsequences: false).last ?? "").trimmingCharacters(in: .whitespaces) : argument
            let used = Set(argument.split(separator: ",").dropLast().map { $0.trimmingCharacters(in: .whitespaces) })
            let names: [String]
            switch command {
            case "usepackage", "RequirePackage": names = Self.packages
            case "documentclass": names = Self.classes
            case "includegraphics": names = paths.filter { ["pdf", "png", "jpg", "jpeg", "eps", "svg"].contains(($0 as NSString).pathExtension.lowercased()) }
            case "input", "include": names = paths.filter { ($0 as NSString).pathExtension.lowercased() == "tex" }
            case "bibliography", "addbibresource": names = paths.filter { ($0 as NSString).pathExtension.lowercased() == "bib" }.map { command == "bibliography" ? ($0 as NSString).deletingPathExtension : $0 }
            default:
                refresh(buffers, selected: file)
                if command == "begin" || command == "end" {
                    let environments = Set(entries.values.flatMap(\.environments))
                    let items = environments.filter { $0.hasPrefix(prefix) }.sorted().prefix(12).map { name -> EditorCompletion.Item in
                        let closing = selection.location < text.length && text.character(at: selection.location) == 125 ? 1 : 0
                        let tail = text.substring(with: NSRange(location: selection.location + closing, length: min(1000, text.length - selection.location - closing)))
                        let insertion = name + "}" + (command == "begin" && !tail.contains("\\end{\(name)}") ? "\n    \n\\end{\(name)}" : "")
                        return .init(label: name, insertion: insertion, caret: command == "begin" && insertion.contains("\n") ? (name as NSString).length + 6 : nil)
                    }
                    guard !items.isEmpty else { return nil }
                    let closing = selection.location < text.length && text.character(at: selection.location) == 125 ? 1 : 0
                    return .init(range: NSRange(location: selection.location - (prefix as NSString).length, length: (prefix as NSString).length + closing), items: Array(items))
                }
                names = Array(Set(entries.values.flatMap(\.labels)))
            }
            let candidates = names.filter { !used.contains($0) && $0.localizedCaseInsensitiveContains(prefix) }.sorted {
                let a = $0.lowercased().hasPrefix(prefix.lowercased()), b = $1.lowercased().hasPrefix(prefix.lowercased())
                return a == b ? $0 < $1 : a
            }
            guard !candidates.isEmpty else { return nil }
            return .init(range: NSRange(location: selection.location - (prefix as NSString).length, length: (prefix as NSString).length), items: candidates.prefix(12).map { .init(label: $0, insertion: $0) })
        }
        guard let command = suffix.range(of: #"(?<!\\)\\[A-Za-z@]{2,}$"#, options: .regularExpression).nonEmpty else { return nil }
        let prefix = suffix.substring(with: command)
        refresh(buffers, selected: file)
        var seen = Set<String>()
        let items = entries.keys.sorted().flatMap { entries[$0]!.commands }.filter { $0.insertion.hasPrefix(prefix) && seen.insert($0.label).inserted }
        guard !items.isEmpty else { return nil }
        let generic = EditorCompletion.context(source, selection: selection, tex: true)
        return .init(range: NSRange(location: selection.location - (prefix as NSString).length, length: (prefix as NSString).length), items: Array((items + (generic?.items ?? [])).prefix(12)))
    }
    private func refresh(_ buffers: [String: String], selected: String) {
        var budget = Self.sourceBudget, retained = Set<String>()
        let paths = buffers.keys.filter { $0.lowercased().hasSuffix(".tex") }.sorted { a, b in a == selected ? b != selected : b == selected ? false : a < b }
        for path in paths.prefix(128) {
            guard !Task.isCancelled, budget > 0, let source = buffers[path] else { break }
            let text = source as NSString, length = min(text.length, Self.fileBudget, budget)
            let bounded = text.substring(with: NSRange(location: 0, length: length)); budget -= length; retained.insert(path)
            guard entries[path]?.source != bounded else { continue }
            let clean = Self.comments.stringByReplacingMatches(in: bounded, range: NSRange(location: 0, length: length), withTemplate: "$1") as NSString
            func values(_ regex: NSRegularExpression, _ limit: Int, transform: (NSTextCheckingResult) -> String) -> [String] {
                var names: [String] = []
                regex.enumerateMatches(in: clean as String, range: NSRange(location: 0, length: clean.length)) { match, _, stop in
                    guard !Task.isCancelled, names.count < limit else { stop.pointee = true; return }
                    if let match { names.append(transform(match)) }
                }
                return names
            }
            let labels = values(Self.labelPattern, 1000) { clean.substring(with: $0.range(at: 1)) }
            var commands: [EditorCompletion.Item] = []
            _ = values(Self.commandPattern, 256) { match in
                let name = clean.substring(with: match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1))
                let count = match.range(at: 3).location == NSNotFound ? 0 : Int(clean.substring(with: match.range(at: 3))) ?? 0
                let required = max(0, count - (match.range(at: 4).location == NSNotFound ? 0 : 1))
                let insertion = "\\" + name + String(repeating: "{}", count: required)
                commands.append(.init(label: insertion, insertion: insertion, caret: MathCompletion.insertionSelection(insertion, location: 0).location, detail: "Defined in " + path))
                return name
            }
            for name in values(Self.operatorPattern, 128, transform: { clean.substring(with: $0.range(at: 1)) }) { commands.append(.init(label: "\\" + name, insertion: "\\" + name, detail: "Defined in " + path)) }
            let environments = values(Self.environmentPattern, 128) { clean.substring(with: $0.range(at: 1)) }
            guard !Task.isCancelled else { return }
            entries[path] = .init(source: bounded, labels: labels, commands: commands, environments: environments); preparations += 1
        }
        entries = entries.filter { retained.contains($0.key) }
    }
}

private extension NSRange {
    var nonEmpty: NSRange? { location != NSNotFound && length > 0 ? self : nil }
}
