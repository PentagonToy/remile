import Foundation

struct TeXDiagnostic: Identifiable {
    enum Severity { case error, warning, info }
    let id: Int
    let severity: Severity
    let message: String
    let file: String?
    let line: Int?
    var isBuildSummary: Bool { message.hasPrefix("Latexmk: Errors") || message.hasPrefix("Latexmk: Could not") }
    var displayMessage: String {
        if isBuildSummary { return "Build stopped. See Terminal for details." }
        return message.replacingOccurrences(of: #"^(?:!\s+|LaTeX (?:Font )?(?:Warning|Error):\s*)"#,
                                            with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^Package ([^\s]+) Warning:\s*"#, with: "$1: ", options: .regularExpression)
    }
}

enum TeXDiagnostics {
    static func displayed(_ entries: [TeXDiagnostic]) -> [TeXDiagnostic] {
        let ordered = prioritised(entries)
        guard ordered.contains(where: { $0.severity == .error && !isFollowUp($0) }) else { return ordered }
        return ordered.filter { !isFollowUp($0) }
    }
    private static func isFollowUp(_ entry: TeXDiagnostic) -> Bool {
        entry.severity == .error && (entry.isBuildSummary || entry.message.contains("Emergency stop")
            || entry.message.contains("Fatal error occurred"))
    }
    static func priority(_ entry: TeXDiagnostic) -> Int {
        let text = entry.message.lowercased()
        if entry.severity == .error {
            if entry.isBuildSummary || text.contains("emergency stop") || text.contains("fatal error occurred") { return 9 }
            if text.contains("documentclass") || text.contains("missing \\begin{document}") { return 0 }
            if text.contains("not found") || text.contains("not loadable") || text.contains("option clash") || text.contains("runaway argument") || text.contains("file ended while scanning") { return 1 }
            return 2
        }
        if entry.severity == .warning {
            if text.contains("undefined") || text.contains("rerun") || text.contains("not found") { return 4 }
            if text.contains("overfull") || text.contains("underfull") { return 7 }
            return 5
        }
        return 8
    }
    static func prioritised(_ entries: [TeXDiagnostic]) -> [TeXDiagnostic] {
        entries.enumerated().sorted {
            let left = priority($0.element), right = priority($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    /// Add only directly observed source mistakes, never a guessed missing class.
    static func assessed(_ entries: [TeXDiagnostic], main: String, source: String) -> [TeXDiagnostic] {
        guard entries.contains(where: { $0.severity == .error }) else { return prioritised(entries) }
        let lines = Array(source.components(separatedBy: .newlines).prefix(200).prefix { !$0.contains("\\begin{document}") })
        guard !lines.contains(where: { $0.range(of: #"^\s*\\documentclass\b"#, options: .regularExpression) != nil }) else { return prioritised(entries) }
        let bareClass = #"^\s*documentclass\s*(?:\[[^\]]*\]\s*)?\{"#
        if let index = lines.prefix(200).firstIndex(where: { $0.range(of: bareClass, options: .regularExpression) != nil }) {
            let root = TeXDiagnostic(id: -1, severity: .error, message: "Missing \\ before \\documentclass. Later errors may follow from this.", file: main, line: index + 1)
            return [root] + prioritised(entries)
        }
        return prioritised(entries)
    }
    static func repairFocus(_ selected: TeXDiagnostic, entries: [TeXDiagnostic]) -> TeXDiagnostic {
        let first = prioritised(entries).first
        return first.map { priority($0) < 2 ? $0 : selected } ?? selected
    }
    static func repairEvidence(selected: TeXDiagnostic, focus: TeXDiagnostic, entries: [TeXDiagnostic], file: String, excerpt: String, main: String, preamble: String) -> [String: Any] {
        func row(_ entry: TeXDiagnostic) -> [String: Any] {
            ["message": String(entry.message.prefix(1200)), "file": entry.file ?? "", "line": entry.line ?? 0]
        }
        let header = preamble.components(separatedBy: .newlines).prefix(160).joined(separator: "\n")
        return ["file": file, "source": excerpt, "diagnostic": row(focus), "selectedDiagnostic": row(selected),
                "checkFirst": prioritised(entries).prefix(6).map(row),
                "earliestErrors": entries.filter { $0.severity == .error }.sorted { $0.id < $1.id }.prefix(12).map(row),
                "mainFile": main, "mainPreamble": String(header.prefix(6000)),
                "errorCount": entries.filter { $0.severity == .error }.count,
                "warningCount": entries.filter { $0.severity == .warning }.count,
                "rankingIsHeuristic": true]
    }
    static func logSeverity(_ entries: [TeXDiagnostic], failed: Bool = false) -> TeXDiagnostic.Severity? {
        if failed { return .error }
        var warning = false
        for entry in entries {
            if entry.severity == .error { return .error }
            if entry.severity == .warning { warning = true }
        }
        return warning ? .warning : nil
    }
    static func primaryError(_ entries: [TeXDiagnostic]) -> TeXDiagnostic? {
        let errors = prioritised(entries).filter { $0.severity == .error }
        return errors.first { entry in
            !["Emergency stop", "Fatal error occurred", "Latexmk: Errors", "Latexmk: Could not"].contains(where: entry.message.contains)
        } ?? errors.first
    }
    /// Parses file-line diagnostics and LaTeX's wrapped warnings; raw output is retained separately.
    static func parse(_ log: String) -> [TeXDiagnostic] {
        let allLines = log.components(separatedBy: .newlines)
        // Earlier passes can contain undefined citations that the final pass resolves.
        let finalPass = allLines.lastIndex { $0.hasPrefix("This is XeTeX") || $0.hasPrefix("This is pdfTeX") || $0.hasPrefix("This is Lua") } ?? 0
        let biberWarnings = allLines[..<finalPass].filter { $0.contains("> WARN - ") }
        let lines = Array(allLines[finalPass...]) + biberWarnings
        let location = try! NSRegularExpression(pattern: #"^(.+?):(\d+):\s*(.+)$"#)
        let inputLine = try! NSRegularExpression(pattern: #"(?:\b(?:input )?lines?\s+|^l\.)\s*(\d+)"#)
        let groups = try! NSRegularExpression(pattern: #"\((?:"([^"]+\.(?:tex|ltx|sty|cls|bbl|cfg|def|fd))"|([^\s()"]+\.(?:tex|ltx|sty|cls|bbl|cfg|def|fd)))(?=[\s()]|$)|[()]"#, options: .caseInsensitive)
        let continuation = try! NSRegularExpression(pattern: #"^\s*\([\w.@-]+\)\s{2,}(.+)$"#)
        let box = try! NSRegularExpression(pattern: #"^(?:Overfull|Underfull) \\[hv]box .*?(?:at lines? \d+(?:--\d+)?|while \\output is active)"#)
        var result: [TeXDiagnostic] = [], seen = Set<String>(), files: [String?] = []
        func sourceLine(_ text: String) -> Int? {
            let value = text as NSString
            guard let match = inputLine.firstMatch(in: text, range: NSRange(location: 0, length: value.length)) else { return nil }
            return Int(value.substring(with: match.range(at: 1)))
        }
        func trackFiles(_ line: String, in value: NSString) {
            for match in groups.matches(in: line, range: NSRange(location: 0, length: value.length)) {
                if value.character(at: match.range.location) == 41 {
                    if !files.isEmpty { files.removeLast() }
                } else {
                    let path = [match.range(at: 1), match.range(at: 2)].first { $0.location != NSNotFound }
                    files.append(path.map { value.substring(with: $0) })
                }
            }
        }
        for (index, line) in lines.enumerated() {
            var file: String?, number: Int?, text = line.trimmingCharacters(in: .whitespaces), severity: TeXDiagnostic.Severity?
            let ns = line as NSString
            if let match = location.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                file = ns.substring(with: match.range(at: 1)); number = Int(ns.substring(with: match.range(at: 2)))
                text = ns.substring(with: match.range(at: 3)); severity = text.localizedCaseInsensitiveContains("warning") ? .warning : .error
            } else if text.hasPrefix("! ") || text.hasPrefix("Runaway argument?") || text.contains("LaTeX Error:") || text.contains("Package ") && text.contains(" Error:") { severity = .error }
            else if text.hasPrefix("Overfull ") || text.hasPrefix("Underfull ") { severity = .info }
            else if text.contains("Warning:") || text.contains("> WARN - ") { severity = .warning }
            else if text.hasPrefix("Latexmk: Errors") || text.hasPrefix("Latexmk: Could not") || text.hasPrefix("Submission check failed:") { severity = .error }
            guard let severity else { trackFiles(line, in: ns); continue }
            if file == nil, !text.contains("> WARN - "), !text.hasPrefix("Latexmk:"),
               !text.hasPrefix("Submission check failed:") { file = files.reversed().compactMap { $0 }.first }
            if severity == .warning {
                for next in lines[(index + 1)..<min(lines.count, index + 5)] {
                    let value = next as NSString
                    guard let match = continuation.firstMatch(in: next, range: NSRange(location: 0, length: value.length)) else { break }
                    text += " " + value.substring(with: match.range(at: 1))
                }
            } else if severity == .info {
                let value = text as NSString
                if let match = box.firstMatch(in: text, range: NSRange(location: 0, length: value.length)) {
                    let suffix = value.substring(from: NSMaxRange(match.range))
                    trackFiles(suffix, in: suffix as NSString)
                    text = value.substring(with: match.range)
                }
            }
            if number == nil { number = sourceLine(text) }
            if number == nil, severity == .error {
                for next in lines[(index + 1)..<min(lines.count, index + 7)] {
                    if next.hasPrefix("! ") || next.contains("Warning:") || next.range(of: #"^.+?:\d+:"# , options: .regularExpression) != nil { break }
                    if next.hasPrefix("l."), let line = sourceLine(next) { number = line; break }
                }
            }
            if text == "Undefined control sequence." {
                let context = lines[(index + 1)..<min(lines.count, index + 4)].joined(separator: " ")
                if let range = context.range(of: #"->\s*(\\[A-Za-z@]+)"#, options: .regularExpression) {
                    let command = context[range].dropFirst(2).trimmingCharacters(in: .whitespaces)
                    text = "Undefined command: \(command)."
                }
            }
            let key = "\(severity)|\(file ?? "")|\(number ?? 0)|\(text)"
            guard seen.insert(key).inserted else { continue }
            result.append(TeXDiagnostic(id: result.count, severity: severity, message: text, file: file, line: number))
        }
        return result
    }
}
