import Foundation

struct TeXDiagnostic: Identifiable {
    enum Severity { case error, warning, info }
    let id: Int
    let severity: Severity
    let message: String
    let file: String?
    let line: Int?
    var isBuildSummary: Bool { message.hasPrefix("Latexmk: Errors") || message.hasPrefix("Latexmk: Could not") }
    var displayMessage: String { isBuildSummary ? "Build stopped. See Terminal for details." : message }
}

enum TeXDiagnostics {
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
        let inputLine = try! NSRegularExpression(pattern: #"(?:input line|l\.)\s*(\d+)"#)
        var result: [TeXDiagnostic] = [], seen = Set<String>()
        for (index, line) in lines.enumerated() {
            var file: String?, number: Int?, text = line.trimmingCharacters(in: .whitespaces), severity: TeXDiagnostic.Severity?
            let ns = line as NSString
            if let match = location.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                file = ns.substring(with: match.range(at: 1)); number = Int(ns.substring(with: match.range(at: 2)))
                text = ns.substring(with: match.range(at: 3)); severity = text.localizedCaseInsensitiveContains("warning") ? .warning : .error
            } else if text.hasPrefix("! ") || text.contains("LaTeX Error:") || text.contains("Package ") && text.contains(" Error:") { severity = .error }
            else if text.contains("Warning:") || text.hasPrefix("Overfull ") || text.hasPrefix("Underfull ") || text.contains("> WARN - ") { severity = .warning }
            else if text.hasPrefix("Latexmk: Errors") || text.hasPrefix("Latexmk: Could not") || text.hasPrefix("Submission check failed:") { severity = .error }
            guard let severity else { continue }
            if number == nil {
                let following = lines[index..<min(lines.count, index + 5)].prefix { !$0.isEmpty }.joined(separator: " ")
                let value = following as NSString
                if let match = inputLine.firstMatch(in: following, range: NSRange(location: 0, length: value.length)) { number = Int(value.substring(with: match.range(at: 1))) }
                text = following
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
