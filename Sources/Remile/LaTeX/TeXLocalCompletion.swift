import Foundation

/// A lazy, bounded project index. Parsing runs on this actor rather than on the UI thread.
actor TeXLocalCompletion {
    private struct Entry {
        let source: String
        let labels: [String]
        let commands: [String]
        let packages: [String]
        let environments: [String]
    }
    private var entries: [String: Entry] = [:]
    private(set) var preparations = 0
    static let sourceBudget = 2_000_000
    static let fileBudget = 256_000
    private static let arguments = try! NSRegularExpression(pattern: #"(?<!\\)\\(includegraphics|includesvg|input|include|subfile|ref|eqref|autoref|pageref|cref|Cref|nameref|usepackage|RequirePackage|documentclass|bibliography|addbibresource|begin|end)\*?\s*(?:\[[^\]]*\]\s*)*\{([^{}\r\n]*)$"#)
    private static let comments = try! NSRegularExpression(pattern: #"(?m)((?<!\\)(?:\\\\)*)%[^\r\n]*"#)
    private static let labelPattern = try! NSRegularExpression(pattern: #"\\label\{([^{}\n]+)\}"#)
    private static let commandPattern = try! NSRegularExpression(pattern: #"\\(?:newcommand|renewcommand|providecommand|DeclareRobustCommand)\*?\s*(?:\{\\([A-Za-z@]+)\}|\\([A-Za-z@]+))\s*(?:\[([0-9])\])?(?:\[([^\]\n]*)\])?"#)
    private static let operatorPattern = try! NSRegularExpression(pattern: #"\\DeclareMathOperator\*?\s*\{\\([A-Za-z@]+)\}"#)
    private static let environmentPattern = try! NSRegularExpression(pattern: #"\\(?:newenvironment|renewenvironment)\*?\s*\{([A-Za-z@*]+)\}"#)
    private static let packagePattern = try! NSRegularExpression(pattern: #"(?<!\\)\\(?:usepackage|RequirePackage)\s*(?:\[[^\]]*\]\s*)?\{([^{}]+)\}"#)
    // Required arguments only. Optional arguments can be supplied in the source.
    private static let packageCommands = [
        "mhchem": [#"\ce{}"#, #"\pu{}"#],
        "siunitx": [#"\num{}"#, #"\unit{}"#, #"\qty{}{}"#, #"\SI{}{}"#, #"\si{}"#],
        "acronym": [#"\ac{}"#, #"\acp{}"#, #"\acs{}"#, #"\acl{}"#, #"\acf{}"#],
    ]
    private static let packages = ["amsmath", "amssymb", "amsthm", "mathtools", "graphicx", "hyperref", "cleveref", "geometry", "fontenc", "inputenc", "babel", "polyglossia", "fontspec", "unicode-math", "biblatex", "natbib", "booktabs", "array", "tabularx", "longtable", "xcolor", "tikz", "pgfplots", "subcaption", "caption", "float", "enumitem", "microtype", "listings", "minted", "url", "csquotes", "setspace"] + packageCommands.keys
    private static let classes = ["article", "report", "book", "letter", "beamer", "memoir", "scrartcl", "scrreprt", "scrbook", "standalone"]

    func context(_ source: String, selection: NSRange, file: String, paths: [String], buffers: [String: String], main: String? = nil) -> EditorCompletion.Context? {
        let text = source as NSString
        guard selection.length == 0, selection.location <= text.length, !Task.isCancelled else { return nil }
        let start = max(0, selection.location - 300)
        let raw = text.substring(with: NSRange(location: start, length: selection.location - start)) as NSString
        let lineStart = max(start, text.lineRange(for: selection).location)
        let line = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        // Earlier comments can appear between the command and its argument.
        guard Self.comments.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) == nil else { return nil }
        guard raw.contains("\\") else { return nil }
        let suffix = Self.comments.stringByReplacingMatches(in: raw as String, range: NSRange(location: 0, length: raw.length), withTemplate: "$1") as NSString
        if let match = Self.arguments.firstMatch(in: suffix as String, range: NSRange(location: 0, length: suffix.length)) {
            let command = suffix.substring(with: match.range(at: 1)), argument = suffix.substring(with: match.range(at: 2))
            let list = ["usepackage", "RequirePackage", "bibliography", "cref", "Cref"].contains(command)
            let prefix = list ? String(argument.split(separator: ",", omittingEmptySubsequences: false).last ?? "").trimmingCharacters(in: .whitespaces) : argument
            let used = Set(argument.split(separator: ",").dropLast().map { $0.trimmingCharacters(in: .whitespaces) })
            let names: [String]
            switch command {
            case "usepackage", "RequirePackage": names = Self.packages
            case "documentclass": names = Self.classes
            case "input", "include", "subfile", "includegraphics", "includesvg", "addbibresource":
                return Self.fileContext(command, prefix: prefix, text: text, cursor: selection.location, paths: paths)
            case "bibliography": names = paths.filter { ($0 as NSString).pathExtension.lowercased() == "bib" }.map { ($0 as NSString).deletingPathExtension }
            default:
                refresh(buffers, selected: file, main: main)
                if command == "begin" || command == "end" {
                    let projectEnvironments = Set(entries.values.flatMap(\.environments))
                    let environments = projectEnvironments.sorted() + EditorCompletion.environments.filter { !projectEnvironments.contains($0) }
                    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                    return EditorCompletion.environmentContext(environments, name: prefix, text: text, cursor: selection.location,
                                                               expand: command == "begin", indent: indent, limit: 12)
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
        guard let range = EditorCompletion.commandRange(line, text: text, cursor: selection.location) else { return nil }
        let prefix = text.substring(with: range)
        refresh(buffers, selected: file, main: main)
        guard !Task.isCancelled else { return nil }

        var matches: [Substring: (template: String, detail: String)] = [:]
        func add(_ template: String, detail: String) {
            guard template.hasPrefix(prefix) else { return }
            let name = EditorCompletion.commandName(template)
            guard matches[name] == nil else { return }
            matches[name] = (template, detail)
        }
        let sources = [file] + entries.keys.filter { $0 != file }.sorted()
        for path in sources {
            let detail = "Defined in " + path
            for template in entries[path]?.commands ?? [] { add(template, detail: detail) }
        }
        let packages = Set(entries.values.flatMap(\.packages))
        for package in packages.sorted() {
            for template in Self.packageCommands[package] ?? [] { add(template, detail: package + " package") }
        }
        guard !matches.isEmpty else { return nil }
        let exact = matches[Substring(prefix)]
        let projectItems = matches.values.filter { $0.template != exact?.template }
            .sorted { $0.template < $1.template }.prefix(12)
        let generic = EditorCompletion.context(source, selection: selection, tex: true)?.items ?? []
        let remaining = generic.filter { matches[EditorCompletion.commandName($0.label)] == nil }
        var items: [EditorCompletion.Item] = []
        if let exact, exact.template != prefix {
            items.append(EditorCompletion.commandItem(exact.template, text: text, cursor: selection.location, detail: exact.detail))
        }
        items.append(contentsOf: remaining.prefix { EditorCompletion.commandName($0.label) == prefix })
        items.append(contentsOf: projectItems.map {
            EditorCompletion.commandItem($0.template, text: text, cursor: selection.location, detail: $0.detail)
        })
        items.append(contentsOf: remaining.drop { EditorCompletion.commandName($0.label) == prefix })
        return items.isEmpty ? nil : .init(range: range, items: Array(items.prefix(12)))
    }
    private static func fileContext(_ command: String, prefix: String, text: NSString, cursor: Int, paths: [String]) -> EditorCompletion.Context? {
        let extensions: Set<String>
        switch command {
        case "input": extensions = ["", "tex", "txt"]
        case "include", "subfile": extensions = ["", "tex"]
        case "includegraphics": extensions = ["pdf", "png", "jpg", "jpeg", "eps", "svg", "gif", "tif", "tiff"]
        case "includesvg": extensions = ["svg"]
        default: extensions = ["bib"]
        }
        let length = (prefix as NSString).length
        var end = cursor
        while end < min(text.length, cursor + 300) {
            let character = text.character(at: end)
            if character == 125 { end += 1; break }
            if [10, 13, 123, 37, 92].contains(character) { end = cursor; break }
            end += 1
        }
        if end > cursor, text.character(at: end - 1) != 125 { end = cursor }
        let omitTeXExtension = ["input", "include", "subfile"].contains(command)
        var items: [EditorCompletion.Item] = [], fallback: [EditorCompletion.Item] = [], seen = Set<String>()
        for path in paths where extensions.contains((path as NSString).pathExtension.lowercased()) {
            guard !Task.isCancelled else { return nil }
            let match = path.range(of: prefix, options: .caseInsensitive)
            guard prefix.isEmpty || match != nil else { continue }
            let short = omitTeXExtension ? TeXFileSystem.reference(path) : path
            let insertion = (prefix.lowercased().contains(".tex") ? path : short) + "}"
            guard seen.insert(insertion).inserted else { continue }
            let item = EditorCompletion.Item(label: path, insertion: insertion)
            if prefix.isEmpty || match?.lowerBound == path.startIndex { items.append(item) }
            else if fallback.count < 12 { fallback.append(item) }
            if items.count == 12 { break }
        }
        items.append(contentsOf: fallback.prefix(12 - items.count))
        return items.isEmpty ? nil : .init(range: NSRange(location: cursor - length, length: end - cursor + length), items: items)
    }
    private func refresh(_ buffers: [String: String], selected: String, main: String?) {
        var budget = Self.sourceBudget, retained = Set<String>()
        let priority = [selected] + (main.map { $0 == selected ? [] : [$0] } ?? [])
        func isSource(_ path: String) -> Bool {
            ["tex", "sty", "cls"].contains((path as NSString).pathExtension.lowercased())
        }
        let paths = priority.filter(isSource) + buffers.keys.filter { !priority.contains($0) && isSource($0) }.sorted()
        for path in paths.prefix(128) {
            guard !Task.isCancelled, budget > 0 else { break }
            guard let source = buffers[path] else { continue }
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
            let definitions = values(Self.commandPattern, 256) { match in
                let name = clean.substring(with: match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1))
                let count = match.range(at: 3).location == NSNotFound ? 0 : Int(clean.substring(with: match.range(at: 3))) ?? 0
                let required = max(0, count - (match.range(at: 4).location == NSNotFound ? 0 : 1))
                return "\\" + name + String(repeating: "{}", count: required)
            }
            let operators = values(Self.operatorPattern, 128) { "\\" + clean.substring(with: $0.range(at: 1)) }
            let packages = values(Self.packagePattern, 128) { clean.substring(with: $0.range(at: 1)) }
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { Self.packageCommands[$0] != nil }
            let environments = values(Self.environmentPattern, 128) { clean.substring(with: $0.range(at: 1)) }
            guard !Task.isCancelled else { return }
            entries[path] = .init(source: bounded, labels: labels, commands: definitions + operators, packages: packages, environments: environments); preparations += 1
        }
        entries = entries.filter { retained.contains($0.key) }
    }
}
