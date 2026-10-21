import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let root = output.appendingPathComponent("Project"), bin = output.appendingPathComponent("Tools")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
let source = "\\documentclass{article}\n\\begin{document}Fixture\\end{document}"
try source.write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
func executable(_ name: String, source: String) throws {
 let path = bin.appendingPathComponent(name)
 try source.write(to: path, atomically: true, encoding: .utf8)
 try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
}
try executable("pdflatex", source: "#!/bin/sh\nexit 0\n")
precondition(TeXConfiguration(directory: bin.path, engine: .pdf).timeLimitSeconds == 180)
for invalid in [0, -1, 1801] { precondition(TeXConfiguration.validatedTimeLimit(invalid) == 180) }
for value in TeXConfiguration.timeLimitOptions { precondition(TeXConfiguration.validatedTimeLimit(value) == value) }
try executable("latexmk", source: "#!/bin/sh\nexec /bin/sleep 10\n")
let started = Date()
do {
 _ = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": source], configuration: TeXConfiguration(directory: bin.path, engine: .pdf, bibliography: false, timeLimit: 1), output: output.appendingPathComponent("TimedOut"))
 fatalError("Missing timeout")
} catch TeXCompileJob.Failure.timeLimit {} catch { fatalError("Wrong timeout error: \(error)") }
precondition(Date().timeIntervalSince(started) < 4)
let log = try String(contentsOf: output.appendingPathComponent("TimedOut/compiler.log"), encoding: .utf8)
precondition(log.contains("Compilation time limit: 1 seconds."))
precondition(TeXDiagnostics.parse(log).contains { $0.severity == .error && $0.message.contains("time limit") })
precondition(log.contains("Settings → LaTeX → Compilation"))
let job = TeXCompileJob()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { job.stop() }
do {
 _ = try job.run(root: root, main: "main.tex", buffers: ["main.tex": source], configuration: TeXConfiguration(directory: bin.path, engine: .pdf, bibliography: false, timeLimit: 5), output: output.appendingPathComponent("Stopped"))
 fatalError("Missing cancellation")
} catch is CancellationError {} catch { fatalError("Wrong cancellation error: \(error)") }
try executable("latexmk", source: "#!/bin/sh\nprintf 'Fixture compiler completed\\n'\nexit 0\n")
let result = try TeXCompileJob().run(root: root, main: "main.tex", buffers: ["main.tex": source], configuration: TeXConfiguration(directory: bin.path, engine: .pdf, bibliography: false, timeLimit: 5), output: output.appendingPathComponent("Completed"))
precondition(result.log.contains("Fixture compiler completed"))
precondition(!result.log.contains("time limit reached"))
print("Passed default/preset/invalid compile limits, real process timeout, actionable diagnostics, manual stop distinction and normal completion")
