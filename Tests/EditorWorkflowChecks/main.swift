import AppKit
import SwiftUI

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0 }
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); checks += 1 }
Task { @MainActor in
    do {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        let main = "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}\n"
        try main.write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try "\\section{First}\nBody\n\\subsection{Nested}\n% \\section{Ignored}".write(to: root.appendingPathComponent("contents/part.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(root)
        expect(project.selected == "main.tex", "Main opens")
        project.selected = "contents/part.tex"; project.goBack(); expect(project.selected == "main.tex", "Back navigation")
        project.goForward(); expect(project.selected == "contents/part.tex", "Forward navigation")
        let outline = TeXOutlineItem.parse(project.source.wrappedValue)
        expect(outline.count == 2 && outline.last?.level == 1, "Outline excludes comments and retains hierarchy")
        project.move("contents/part.tex", to: "other/renamed.tex")
        expect(project.buffers["other/renamed.tex"] != nil && project.buffers["contents/part.tex"] == nil, "Move remaps the editor buffer")
        expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("other/renamed.tex").path), "Move reaches disk")
        do { try TeXFileSystem.move(root: root, from: "main.tex", to: "other/renamed.tex"); fatalError("Collision allowed") } catch { checks += 1 }
        do { _ = try TeXFileSystem.url("../escape.tex", root: root); fatalError("Traversal allowed") } catch { checks += 1 }
        let before = project.source.wrappedValue
        project.captureHistory(file: project.selected)
        project.source.wrappedValue += "\nNew edit"
        project.captureHistory(file: project.selected)
        let old = project.revisions.first { $0.file == project.selected && $0.source == before }!
        project.restore(old)
        expect(project.source.wrappedValue == before, "History restores into the buffer")
        let saved = try String(contentsOf: root.appendingPathComponent(project.selected), encoding: .utf8)
        expect(saved == before, "History does not write changes automatically")
        project.buffers["main.tex"] = main + "% unsaved"
        try (main + "% external").write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        expect(!project.save(), "External save conflict is preserved")
        expect(EditorBridge.digest("a") != EditorBridge.digest("b"), "CLI uses source fingerprints")
        expect(RecentReadingRow.relativeDate(Date()) == "Today", "Recent opening dates")
        print("Passed \(checks) editor workflow checks")
        exit(0)
    } catch { print(error); exit(1) }
}
RunLoop.main.run()
