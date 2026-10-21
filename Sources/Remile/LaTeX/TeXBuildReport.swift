import Foundation

/// Installation hints are derived from diagnostics, never executed by the app.
struct TeXSetupIssue: Equatable, Sendable {
    let files: [String]
    var ghostscript = false
    var managerNeedsUpdate = false
    static func detect(_ log: String) -> Self? {
        let pattern = try! NSRegularExpression(pattern: "[Ff]ile [`'\"]([A-Za-z0-9][A-Za-z0-9_.-]*\\.(?:sty|cls|tex|def|fd|tfm|pfb|otf|ttf|map|enc|bst))['`\"] (?:not found|not loadable)")
        let text = log as NSString
        var files = Set(pattern.matches(in: log, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: 1)) })
        let fonts = try! NSRegularExpression(pattern: #"Font [^\n=]+=([A-Za-z0-9][A-Za-z0-9_.-]*) at [^\n]*not loadable"#)
        for match in fonts.matches(in: log, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            files.insert(name.hasSuffix(".tfm") ? name : name + ".tfm")
        }
        let gs = log.contains("program gs not found") || log.contains("gs: command not found")
        let update = log.contains("tlmgr itself needs to be updated")
        return files.isEmpty && !gs && !update ? nil : Self(files: files.sorted(), ghostscript: gs, managerNeedsUpdate: update)
    }
    func commands(directory: String, resolution: TeXPackageResolution? = nil) -> [String] {
        let manager = Self.quote(URL(fileURLWithPath: directory).appendingPathComponent("tlmgr").path)
        let packages = Array(Set(files.compactMap { file -> String? in
            guard let owners = resolution?.owners[file], owners.count == 1 else { return nil }; return owners.first
        })).sorted()
        var commands = managerNeedsUpdate || resolution?.managerNeedsUpdate == true ? ["sudo " + manager + " update --self"] : []
        if !packages.isEmpty { commands.append("sudo " + manager + " install " + packages.joined(separator: " ")) }
        for file in files where resolution?.owners[file]?.count != 1 {
            commands.append(manager + " search --global --file " + Self.quote("/" + NSRegularExpression.escapedPattern(for: file) + "$") )
        }
        if ghostscript { commands.append("brew install ghostscript") }
        return commands
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Classifies actionable failures separately from warnings and cascading fatal messages.
struct TeXBuildReport {
    enum Category: String { case tools = "TeX tools", dependencies = "Dependencies", source = "Source", compiler = "Compiler" }
    struct Problem: Identifiable {
        let id: String
        let category: Category
        let message: String
        var diagnostic: TeXDiagnostic? = nil
    }
    let issue: TeXSetupIssue?
    let problems: [Problem]
    init(log: String, diagnostics: [TeXDiagnostic], missingTools: [String]) {
        issue = TeXSetupIssue.detect(log)
        var result: [Problem] = []
        if !missingTools.isEmpty { result.append(Problem(id: "tools", category: .tools, message: missingTools.joined(separator: ", "))) }
        if let issue { result.append(Problem(id: "dependencies", category: .dependencies, message: issue.files.isEmpty ? (issue.managerNeedsUpdate ? "Update TeX Live Manager" : "Ghostscript is missing") : issue.files.joined(separator: ", "))) }
        var seen = Set<String>()
        for entry in diagnostics where entry.severity == .error {
            guard !["Emergency stop", "Fatal error occurred", "Latexmk: Errors", "Latexmk: Could not"].contains(where: entry.message.contains) else { continue }
            if issue != nil && (TeXSetupIssue.detect(entry.message) != nil || entry.message.contains("can't find file") || entry.message.contains("failed to make")) { continue }
            let key = (entry.file ?? "") + ":\(entry.line ?? 0):" + entry.message
            if seen.insert(key).inserted { result.append(Problem(id: key, category: entry.file == nil ? .compiler : .source, message: entry.message, diagnostic: entry)) }
        }
        if result.isEmpty, let entry = TeXDiagnostics.primaryError(diagnostics) { result.append(Problem(id: "compiler", category: .compiler, message: entry.message, diagnostic: entry)) }
        problems = result
    }
}
