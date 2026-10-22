import Foundation

struct TeXConfiguration: Sendable {
    enum Engine: String, CaseIterable { case automatic = "Automatic", pdf = "pdfLaTeX", xe = "XeLaTeX", lua = "LuaLaTeX" }
    var directory: String
    var engine: Engine
    var bibliography = true
    var timeLimit = 180
    static let timeLimitOptions = [90, 180, 300, 600]
    static func validatedTimeLimit(_ value: Int?) -> Int { value.flatMap { (1...1800).contains($0) ? $0 : nil } ?? 180 }
    var timeLimitSeconds: TimeInterval { TimeInterval(Self.validatedTimeLimit(timeLimit)) }
    static var current: Self { Self(directory: UserDefaults.standard.string(forKey: "latex.binDirectory") ?? "/Library/TeX/texbin", engine: Engine(rawValue: UserDefaults.standard.string(forKey: "latex.engine") ?? "") ?? .automatic, bibliography: UserDefaults.standard.object(forKey: "latex.bibliography") as? Bool ?? true, timeLimit: validatedTimeLimit(UserDefaults.standard.object(forKey: "latex.compileTimeLimit") as? Int)) }
    func missingTools(buffers: [String: String], submissionCheck: Bool = false) -> [String] {
        let resolved = engine == .automatic ? (buffers.values.contains { $0.contains("fontspec") || $0.contains("\\setmainfont") } ? Engine.xe : Engine.pdf) : engine
        let names = (submissionCheck ? [] : ["latexmk"]) + [resolved == .xe ? "xelatex" : resolved == .lua ? "lualatex" : "pdflatex"]
        return names.filter { !FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent($0).path) }
    }
    // MacTeX installs Ghostscript in /usr/local/bin, including on Apple Silicon.
    var executablePath: String { directory + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
    var available: Bool { FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent("latexmk").path) }
}

/// Explicit compile jobs never run project rc files or save editor buffers to the original tree.
final class TeXCompileJob: @unchecked Sendable {
    enum Failure: LocalizedError {
        case timeLimit
        var errorDescription: String? { "Compilation time limit reached. Increase it in Settings → LaTeX → Compilation, then try again." }
    }
    struct Result { let pdf: Data?; let log: String; let output: URL; let success: Bool }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let publish: @Sendable (String) -> Void
    init(publish: @escaping @Sendable (String) -> Void = { _ in }) { self.publish = publish }
    func stop() { lock.lock(); cancelled = true; let active = process; lock.unlock(); if active?.isRunning == true { active?.interrupt() } }
    func run(root: URL, main: String, buffers: [String: String], configuration: TeXConfiguration, output: URL, scratch: Bool = false, submissionCheck: Bool = false) throws -> Result {
        guard configuration.missingTools(buffers: buffers, submissionCheck: submissionCheck).isEmpty else { throw CocoaError(.executableNotLoadable) }
        let manager = FileManager.default
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        let source = output.appendingPathComponent("Source"), build = output.appendingPathComponent("Build")
        try TeXSourceSnapshot.write(root: root, buffers: buffers, to: source, submissionCheck: submissionCheck)
        try manager.createDirectory(at: build, withIntermediateDirectories: true)
        let executable = URL(fileURLWithPath: configuration.directory).appendingPathComponent("latexmk")
        let engine: TeXConfiguration.Engine = configuration.engine == .automatic ? (buffers.values.contains { $0.contains("fontspec") || $0.contains("\\setmainfont") } ? .xe : .pdf) : configuration.engine
        let flag = engine == .xe ? "-xelatex" : engine == .lua ? "-lualatex" : "-pdf"
        let logURL = output.appendingPathComponent("compiler.log"); manager.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL); defer { try? handle.close() }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = configuration.executablePath
        let deadline = Date().addingTimeInterval(configuration.timeLimitSeconds)
        try handle.write(contentsOf: Data("Compilation time limit: \(Int(configuration.timeLimitSeconds)) seconds.\n".utf8))
        if engine == .pdf, let items = manager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            let converter = URL(fileURLWithPath: configuration.directory).appendingPathComponent("epstopdf")
            for case let image as URL in items where image.pathExtension.lowercased() == "eps" {
                let target = image.deletingPathExtension().path + "-eps-converted-to.pdf"
                guard !manager.fileExists(atPath: target) else { continue }
                guard manager.isExecutableFile(atPath: converter.path) else { throw TeXFileSystem.Failure(errorDescription: "EPS graphics need epstopdf from your TeX installation.") }
                let status = try execute(converter, arguments: ["--restricted", "--outfile=" + URL(fileURLWithPath: target).lastPathComponent, "./" + image.lastPathComponent], directory: image.deletingLastPathComponent(), environment: environment, log: handle, logURL: logURL, deadline: deadline)
                guard status == 0, manager.fileExists(atPath: target) else { throw TeXFileSystem.Failure(errorDescription: "Could not prepare the EPS graphic “\(image.lastPathComponent)”. See the build log.") }
            }
        }
        if submissionCheck {
            let tool = URL(fileURLWithPath: configuration.directory).appendingPathComponent(engine == .xe ? "xelatex" : engine == .lua ? "lualatex" : "pdflatex")
            environment["TEXINPUTS"] = source.path + "//:"
            environment.removeValue(forKey: "TEXMFOUTPUT")
            try handle.write(contentsOf: Data("Submission check: fresh snapshot, no .bib/.bbl/.bst or cached auxiliary files. Three LaTeX passes. BibTeX/Biber/latexmk not invoked. This uses the installed engine, not a publisher's historical distribution.\n".utf8))
            var status: Int32 = 0
            for pass in 1...3 {
                try handle.write(contentsOf: Data("Submission check: LaTeX pass \(pass)/3\n".utf8))
                status = try execute(tool, arguments: ["-interaction=nonstopmode", "-halt-on-error", "-file-line-error", "-no-shell-escape", "-recorder", "-synctex=1", "-output-directory=\(build.path)", "./" + main], directory: source, environment: environment, log: handle, logURL: logURL, deadline: deadline)
                if status != 0 { break }
            }
            let name = ((main as NSString).lastPathComponent as NSString).deletingPathExtension
            let finalLog = (try? Data(contentsOf: build.appendingPathComponent(name + ".log"))).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let recorder = (try? String(contentsOf: build.appendingPathComponent(name + ".fls"), encoding: .utf8)) ?? ""
            let dependency = recorder.components(separatedBy: .newlines).contains { line in
                guard line.hasPrefix("INPUT ") else { return false }
                return ["bib", "bbl", "bst"].contains((String(line.dropFirst(6)) as NSString).pathExtension.lowercased())
            }
            let needsBibliography = finalLog.range(of: #"No file [^\n]*\.bbl"#, options: .regularExpression) != nil || finalLog.contains("Please (re)run Biber") || finalLog.contains("Please (re)run BibTeX")
            let unresolved = needsBibliography || finalLog.contains("undefined citations") || finalLog.contains("undefined references") || finalLog.range(of: #"Citation[^\n]*undefined"#, options: .regularExpression) != nil || finalLog.contains("Rerun to get cross-references right")
            let passed = status == 0 && !recorder.isEmpty && !finalLog.isEmpty && !dependency && !unresolved
            let summary = passed ? "Submission check passed: references resolved without bibliography files or bibliography processors." : "Submission check failed: " + (status != 0 ? "LaTeX compilation failed." : dependency ? "A bibliography file was read, including an external path." : unresolved ? "Unresolved citations or references remain after three passes." : "No dependency record was produced.")
            try handle.write(contentsOf: Data((summary + "\n").utf8))
            let text = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
            let pdfURL = build.appendingPathComponent(name + ".pdf")
            let pdf = passed ? try? Data(contentsOf: pdfURL) : nil
            return Result(pdf: pdf, log: String(text.suffix(150000)), output: pdfURL, success: pdf != nil)
        }
        if configuration.bibliography {
            let biber = URL(fileURLWithPath: configuration.directory).appendingPathComponent("biber")
            if manager.isExecutableFile(atPath: biber.path) {
                let input = try FileHandle(forReadingFrom: biber); defer { try? input.close() }
                let magic = Array(try input.read(upToCount: 4) ?? Data())
                // Packed universal Biber uses an obsolete lipo option on some macOS releases.
                // Prepare only a build-local architecture slice. Never alter the TeX installation.
                if [[0xca, 0xfe, 0xba, 0xbe], [0xca, 0xfe, 0xba, 0xbf], [0xbe, 0xba, 0xfe, 0xca], [0xbf, 0xba, 0xfe, 0xca]].contains(magic.map(Int.init)) {
                    #if arch(arm64)
                    let architecture = "arm64"
                    #else
                    let architecture = "x86_64"
                    #endif
                    let tools = output.appendingPathComponent("Tools")
                    try manager.createDirectory(at: tools, withIntermediateDirectories: true)
                    let status = try execute(URL(fileURLWithPath: "/usr/bin/lipo"), arguments: [biber.path, "-thin", architecture, "-o", tools.appendingPathComponent("biber").path], directory: source, environment: environment, log: handle, logURL: logURL, deadline: deadline)
                    if status == 0 {
                        environment["PATH"] = tools.path + ":" + environment["PATH"]!
                        try handle.write(contentsOf: Data("Biber: using a build-local \(architecture) copy. Installed TeX tools unchanged.\n".utf8))
                    }
                }
            }
        }
        let status = try execute(executable, arguments: (scratch ? ["-gg"] : []) + ["-norc", flag, configuration.bibliography ? "-bibtex" : "-bibtex-", "-interaction=nonstopmode", "-file-line-error", "-no-shell-escape", "-synctex=1", "-outdir=\(build.path)", "./" + main], directory: source, environment: environment, log: handle, logURL: logURL, deadline: deadline)
        let text = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        let pdfURL = build.appendingPathComponent(((main as NSString).lastPathComponent as NSString).deletingPathExtension + ".pdf")
        let pdf = try? Data(contentsOf: pdfURL)
        return Result(pdf: pdf, log: String(text.suffix(150000)), output: pdfURL, success: status == 0 && pdf != nil)
    }
    private func execute(_ executable: URL, arguments: [String], directory: URL, environment: [String: String], log: FileHandle, logURL: URL, deadline: Date) throws -> Int32 {
        let child = Process(); child.executableURL = executable; child.arguments = arguments; child.currentDirectoryURL = directory
        child.environment = environment; child.standardOutput = log; child.standardError = log
        lock.lock(); if cancelled { lock.unlock(); throw CancellationError() }; process = child
        do { try child.run(); lock.unlock() } catch { lock.unlock(); throw error }
        var nextOutput = Date.distantPast
        var timedOut = false
        while child.isRunning {
            if Date() >= nextOutput {
                if let reader = try? FileHandle(forReadingFrom: logURL) {
                    if let length = try? reader.seekToEnd() { try? reader.seek(toOffset: length > 150000 ? length - 150000 : 0); if let data = try? reader.read(upToCount: 150000) { publish(String(decoding: data, as: UTF8.self)) } }
                    try? reader.close()
                }
                nextOutput = Date().addingTimeInterval(0.3)
            }
            if Date() > deadline { timedOut = true; stop(); Thread.sleep(forTimeInterval: 0.3); if child.isRunning { child.terminate() }; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        child.waitUntilExit(); lock.lock(); let stopped = cancelled; process = nil; lock.unlock()
        if timedOut {
            let message = Failure.timeLimit.localizedDescription
            try log.write(contentsOf: Data(("\n! " + message + "\n").utf8))
            throw Failure.timeLimit
        }
        if stopped { throw CancellationError() }
        return child.terminationStatus
    }
}
