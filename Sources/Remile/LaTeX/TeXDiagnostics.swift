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
        let errors = entries.filter { $0.severity == .error }
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
