import AppKit
import SwiftUI

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0 }
Task { @MainActor in
 do {
let folder = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("fixture")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let baseline = "\\documentclass{article}\n% TODO author note\n\\begin{document}Hello\\end{document}\n"
try baseline.write(to: folder.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
let project = try TeXProject(folder)
let historyCount = project.revisions.count
project.buffers["main.tex"] = baseline + " "
project.captureHistory(file: "main.tex", automatic: true)
precondition(project.revisions.count == historyCount)
project.captureHistory(file: "main.tex")
precondition(project.revisions.count == historyCount + 1)
project.captureHistory(file: "main.tex")
precondition(project.revisions.count == historyCount + 1)
project.buffers["main.tex"] = baseline
project.captureHistory(file: "main.tex")
precondition(TeXHistory.intervalMinutes >= 1 && TeXHistory.intervalMinutes <= 30)
let edit = try TeXTools.prepare("strip-notes", project: project, file: "main.tex")
precondition(edit.count == 1)
precondition(project.applyTool(file: "main.tex", before: baseline, after: edit.source, name: edit.title, feedback: false))
precondition(project.revisions.prefix(2).allSatisfy { $0.marker != nil })
precondition(project.revisions.first?.marker?.hasPrefix("After") == true)
let disk = try String(contentsOf: folder.appendingPathComponent("main.tex"), encoding: .utf8)
precondition(disk == baseline)
precondition(!project.applyTool(file: "main.tex", before: baseline, after: "bad", name: "stale", feedback: false))
let snapshot = folder.deletingLastPathComponent().appendingPathComponent("Snapshot")
try TeXSourceSnapshot.write(root: folder, buffers: project.buffers, to: snapshot)
let snap = try String(contentsOf: snapshot.appendingPathComponent("main.tex"), encoding: .utf8)
precondition(snap == edit.source)
let archive = folder.deletingLastPathComponent().appendingPathComponent("source.zip")
try TeXSourceSnapshot.export(root: folder, buffers: project.buffers, to: archive)
precondition(FileManager.default.fileExists(atPath: archive.path))
precondition(project.rename("main.tex", to: "renamed.tex"))
precondition(project.main == "renamed.tex")
precondition(project.renameProject(to: "renamed-project"))
precondition(project.root.lastPathComponent == "renamed-project")
precondition(TeXConfiguration(directory: "/no-such-tex", engine: .xe).missingTools(buffers: [:]) == ["latexmk", "xelatex"])
print("Passed editor action checks plus automatic-history coalescing, forced checkpoint and duplicate suppression")

exit(0)
 } catch { print(error); exit(1) }
}
RunLoop.main.run()
