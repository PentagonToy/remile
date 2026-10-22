import AppKit
import SwiftUI

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }

NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]), manager = FileManager.default
        let root = output.appendingPathComponent("project"), incoming = output.appendingPathComponent("incoming")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("\\documentclass{article}\n\\begin{document}Test\\end{document}".utf8).write(to: root.appendingPathComponent("main.tex"))
        let project = try TeXProject(root, historyEnabled: false)
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1; print("PASS: " + label) }
        for name in ["temp.txt", "notes.md", "data.xlsx", "movie.mp4", "archive.zip", "custom.unfamiliar", "LICENSE"] {
            project.newFile()
            check(project.finishNewItem(name), "Create \(name) without an extension allowlist")
            check(manager.fileExists(atPath: root.appendingPathComponent(name).path) && project.treeFiles.contains(name), "Created file is present in the project")
        }
        let bytes = Data([0, 255, 128, 42, 10])
        for name in ["uploaded.xlsx", "uploaded.mp4", "uploaded.unknown", "NO_EXTENSION"] {
            let input = incoming.appendingPathComponent(name)
            try bytes.write(to: input); project.drop([input], into: "")
            let copied = try Data(contentsOf: root.appendingPathComponent(name))
            check(copied == bytes && project.treeFiles.contains(name), "Import \(name) without altering bytes")
            check(project.buffers[name] == nil, "Imported binary is not loaded into the text editor")
        }
        project.newFile()
        check(!project.finishNewItem("temp.txt") && project.newItemError != nil, "Duplicate name remains an actionable validation error")
        project.cancelNewItem()
        check(project.newItemDraft == nil && project.newItemError == nil, "Cancelling clears both the entry and its error")
        project.newFile()
        check(!project.finishNewItem("../outside.txt"), "A name cannot escape the project")
        project.cancelNewItem()
        check(!manager.fileExists(atPath: output.appendingPathComponent("outside.txt").path), "Invalid name writes nothing outside the project")
        do { _ = try TeXFileSystem.importFile(incoming.appendingPathComponent("uploaded.mp4"), root: root, folder: ""); check(false, "Duplicate import must fail") }
        catch { check(try Data(contentsOf: root.appendingPathComponent("uploaded.mp4")) == bytes, "Duplicate import preserves existing bytes") }
        var source = "A small document"
        var controller: MarkdownEditorController? = MarkdownEditorController()
        weak var releasedController = controller
        var hosted: NSHostingView<MarkdownEditor>? = NSHostingView(rootView: MarkdownEditor(source: Binding(get: { source }, set: { source = $0 }), controller: controller!, size: 17, serif: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted; window.orderBack(nil)
        hosted?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        controller?.changed("Updated source")
        check(source == "Updated source", "The native editor still updates its source binding")
        window.contentView = NSView(); window.close(); hosted = nil; controller = nil
        for _ in 0..<20 where releasedController != nil { try await Task.sleep(for: .milliseconds(50)) }
        check(releasedController == nil, "Closing the native editor releases its controller and binding")
        print("Passed \(checks) project file checks")
        exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
NSApplication.shared.run()
