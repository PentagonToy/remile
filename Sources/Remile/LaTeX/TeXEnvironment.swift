import Foundation

struct TeXEnvironmentReport: Sendable {
    let projectChecked: Bool
    let checkedFiles: Int
    let missingTools: [String]
    let missingFiles: [String]
    let unverifiedFiles: [String]
    let needsGhostscript: Bool
    var ready: Bool { missingTools.isEmpty && missingFiles.isEmpty && unverifiedFiles.isEmpty && !needsGhostscript }
    var issue: TeXSetupIssue? {
        missingFiles.isEmpty && !needsGhostscript ? nil : TeXSetupIssue(files: missingFiles, ghostscript: needsGhostscript)
    }
}

/// A read-only local check. No TeX compilation, network lookup or package installation.
enum TeXEnvironment {
    static func declaredFiles(_ buffers: [String: String]) -> [String] {
        let declarations = try! NSRegularExpression(pattern: #"\\(usepackage|RequirePackage|documentclass)(?:\[[^\]]*\])?\{([^}]+)\}"#)
        var files = Set<String>()
        for source in buffers.values {
            let uncommented = source.replacingOccurrences(of: #"(?<!\\)%[^\n]*"#, with: "", options: .regularExpression)
            let text = uncommented as NSString
            for match in declarations.matches(in: uncommented, range: NSRange(location: 0, length: text.length)) {
                let suffix = text.substring(with: match.range(at: 1)) == "documentclass" ? ".cls" : ".sty"
                for name in text.substring(with: match.range(at: 2)).components(separatedBy: ",") {
                    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else { continue }
                    files.insert(name + suffix)
                }
            }
        }
        return files.sorted()
    }
    static func check(configuration: TeXConfiguration, buffers: [String: String]?, root: URL?, projectFiles: [String] = []) -> TeXEnvironmentReport {
        let manager = FileManager.default
        let lookup = URL(fileURLWithPath: configuration.directory).appendingPathComponent("kpsewhich")
        var tools = configuration.missingTools(buffers: buffers ?? [:])
        if !manager.isExecutableFile(atPath: lookup.path) { tools.append("kpsewhich") }
        let required = declaredFiles(buffers ?? [:])
        var missing: [String] = [], unverified: [String] = []
        for file in required {
            if Task.isCancelled { unverified.append(file); continue }
            if let root, manager.fileExists(atPath: root.appendingPathComponent(file).path) { continue }
            guard manager.isExecutableFile(atPath: lookup.path) else { unverified.append(file); continue }
            let child = Process(); child.executableURL = lookup; child.arguments = [file]
            var environment = ProcessInfo.processInfo.environment; environment["PATH"] = configuration.executablePath
            child.environment = environment; child.currentDirectoryURL = root
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            do {
                try child.run()
                let deadline = Date().addingTimeInterval(2)
                while child.isRunning && Date() < deadline && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                if child.isRunning { child.terminate(); unverified.append(file); continue }
                child.waitUntilExit()
                if child.terminationStatus == 1 { missing.append(file) }
                else if child.terminationStatus != 0 { unverified.append(file) }
            } catch { unverified.append(file) }
        }
        let eps = projectFiles.contains { $0.lowercased().hasSuffix(".eps") }
        let gs = configuration.executablePath.components(separatedBy: ":").contains { manager.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent("gs").path) }
        return TeXEnvironmentReport(projectChecked: buffers != nil, checkedFiles: required.count, missingTools: tools, missingFiles: missing, unverifiedFiles: unverified, needsGhostscript: eps && !gs)
    }
}
