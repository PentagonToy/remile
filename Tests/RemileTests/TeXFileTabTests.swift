import XCTest
import SwiftUI
@testable import Remile

@MainActor final class TeXFileTabTests: XCTestCase {
    func testFileTreeSnapshotKeepsEmptyFoldersAndSkipsLinksAndHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folders = root.appendingPathComponent("Figures/Empty")
        try FileManager.default.createDirectory(at: folders, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Main".write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try "Figure".write(to: root.appendingPathComponent("Figures/panel.pdf"), atomically: true, encoding: .utf8)
        try "Hidden".write(to: root.appendingPathComponent(".hidden.tex"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: folders.deletingLastPathComponent())
        let snapshot = try TeXFileSystem.snapshot(root)
        XCTAssertEqual(snapshot.paths, ["Figures/panel.pdf", "main.tex"])
        XCTAssertEqual(snapshot.folders, ["Figures", "Figures/Empty"])
        XCTAssertEqual(try TeXFileSystem.paths(root), snapshot.paths)
        XCTAssertEqual(try TeXFileSystem.folders(root), snapshot.folders)
    }

    func testTabStripLightDarkAndNarrowCaptures() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["main.tex", "method-with-a-long-file-name.tex", "references.bib"] {
            try "\\documentclass{article}\n\\begin{document}Text\\end{document}".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let project = try TeXProject(root, historyEnabled: false)
        project.selected = "references.bib"; project.selected = "method-with-a-long-file-name.tex"
        for dark in [false, true] {
            for width in [560.0, 1200.0] {
                let host = NSHostingView(rootView: TeXFileTabs(project: project, showFiles: {}).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 39)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["REMILE_SOURCE_TAB_CAPTURE"] {
                    let name = "source-tabs-\(dark ? "dark" : "light")-\(Int(width)).png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
    }
    func testRenameEditsNestedRowAndDoesNotOpenFolder() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let figures = root.appendingPathComponent("Figures")
        try FileManager.default.createDirectory(at: figures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Main".write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try "Figure".write(to: figures.appendingPathComponent("before.svg"), atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        let frame = NSRect(x: 0, y: 0, width: 230, height: 520)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TeXProjectSidebar(project: project))
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()

        func findOutline(_ view: NSView) -> NSOutlineView? {
            (view as? NSOutlineView) ?? view.subviews.lazy.compactMap(findOutline).first
        }
        let outline = try XCTUnwrap(findOutline(host))
        func row(_ path: String) -> Int? {
            (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? TeXFileTree.Node)?.file == path }
        }
        func field(_ path: String) -> NSTextField? {
            guard let row = row(path) else { return nil }
            return (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField
        }
        func startRename(_ path: String) async throws -> NSTextField {
            project.newItemDraft = .init(kind: .rename(path))
            for _ in 0..<40 {
                if let field = field(path), field.currentEditor() != nil { return field }
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            return try XCTUnwrap(nil, "Expected the name field at \(path) to have focus.")
        }
        let folderRow = try XCTUnwrap(row("Figures"))
        outline.selectRowIndexes(IndexSet(integer: folderRow), byExtendingSelection: false)
        XCTAssertEqual(project.openFiles, ["main.tex"])
        XCTAssertEqual(project.selected, "main.tex")

        let name = try await startRename("Figures/before.svg")
        let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
        let delegate = try XCTUnwrap(name.delegate as? TeXFileTree.Coordinator)
        XCTAssertEqual(editor.string, "before.svg")
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), "before")
        XCTAssertEqual(outline.level(forRow: try XCTUnwrap(row("Figures/before.svg"))), 1)
        XCTAssertEqual(row("Figures"), folderRow)
        if let directory = ProcessInfo.processInfo.environment["REMILE_SOURCE_TAB_CAPTURE"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("inline-file-rename.png"))
        }

        editor.replaceCharacters(in: editor.selectedRange(), with: "after")
        XCTAssertEqual(editor.string, "after.svg")
        XCTAssertTrue(delegate.control(name, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(FileManager.default.fileExists(atPath: figures.appendingPathComponent("after.svg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: figures.appendingPathComponent("before.svg").path))
        XCTAssertEqual(project.openFiles, ["main.tex"])
        XCTAssertNil(project.newItemDraft)

        let folder = try await startRename("Figures")
        let folderEditor = try XCTUnwrap(folder.currentEditor() as? NSTextView)
        XCTAssertEqual((folderEditor.string as NSString).substring(with: folderEditor.selectedRange()), "Figures")
        folderEditor.string = "Artwork"
        XCTAssertTrue(delegate.control(folder, textView: folderEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(project.treeFolders, ["Figures"])
        XCTAssertEqual(project.selected, "main.tex")
        XCTAssertNil(project.newItemDraft)

        let folderToRename = try await startRename("Figures")
        let editorToCommit = try XCTUnwrap(folderToRename.currentEditor() as? NSTextView)
        editorToCommit.string = "Artwork"
        XCTAssertTrue(window.makeFirstResponder(outline))
        XCTAssertEqual(project.treeFolders, ["Artwork"])
        XCTAssertNotNil(row("Artwork/after.svg"))
        XCTAssertEqual(project.openFiles, ["main.tex"])
    }

    func testFileTreeOrdersFoldersAndKeepsEmptyAndInferredDirectories() {
        let roots = TeXFileNode.tree(
            ["figures/panel10.pdf", "figures/panel2.pdf", "main.tex", "figures/panel2.pdf", "a|b.tex"],
            folders: ["notes", "figures/empty"]
        )
        XCTAssertEqual(roots.map(\.path), ["figures", "notes", "a|b.tex", "main.tex"])
        XCTAssertEqual(roots[0].children?.map(\.path), ["figures/empty", "figures/panel2.pdf", "figures/panel10.pdf"])
        XCTAssertEqual(roots[0].children?.first?.children?.count, 0)
        XCTAssertEqual(roots[1].children?.count, 0)
        XCTAssertNil(roots[2].children)
    }

    func testFileTreeUsesDistinctPDFAndGraphicSymbols() {
        for ext in ["eps", "svg", "jpeg", "PNG", "gif", "tiff"] {
            XCTAssertEqual(TeXFileTree.Coordinator.fileSymbol(for: ext), "photo")
        }
        XCTAssertEqual(TeXFileTree.Coordinator.fileSymbol(for: "PDF"), "doc.richtext")
    }

    func testCLIFileEditsKeepTabsAndActiveSelection() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source = root.appendingPathComponent("project")
        let mailbox = root.appendingPathComponent("mailbox")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mailbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = "Introduction\nKeep the cursor within this sentence.\n"
        let section = "A project section.\n"
        try main.write(to: source.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try section.write(to: source.appendingPathComponent("section.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(source, historyEnabled: false)
        let home = HomeModel(index: LibraryIndex(location: root.appendingPathComponent("index.sqlite")),
                             overleaf: OverleafLibrary(directory: root.appendingPathComponent("overleaf")))
        home.texProject = project
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TeXWorkspace(project: project, close: {}))
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        let editor = try XCTUnwrap(project.sourceEditor.textView)
        XCTAssertNotNil(project.editSource)
        XCTAssertEqual(project.selected, "main.tex")
        let selection = (main as NSString).range(of: "cursor")
        editor.setSelectedRange(selection)

        let service = Task { @MainActor in await EditorBridge.serve({ home }, directory: mailbox) }
        defer { service.cancel() }
        func call(_ request: EditorBridge.Request) async throws -> [String: Any] {
            let requestURL = mailbox.appendingPathComponent(request.id.uuidString + ".request.json")
            let replyURL = mailbox.appendingPathComponent(request.id.uuidString + ".response.json")
            try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: replyURL.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let reply = try JSONSerialization.jsonObject(with: Data(contentsOf: replyURL))
            return try XCTUnwrap(reply as? [String: Any])
        }

        let read = try await call(.init(operation: "read", file: "section.tex"))
        let withNote = section + "% TODO author note\n"
        let replaced = try await call(.init(operation: "replace", file: "section.tex", source: withNote,
                                            expectedSHA256: try XCTUnwrap(read["sha256"] as? String)))
        XCTAssertEqual(replaced["ok"] as? Bool, true)
        XCTAssertEqual(project.buffers["section.tex"], withNote)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.undo()
        XCTAssertEqual(project.buffers["section.tex"], section)
        undo.redo()
        XCTAssertEqual(project.buffers["section.tex"], withNote)

        let transformed = try await call(.init(operation: "transform", file: "section.tex",
                                               expectedSHA256: EditorBridge.digest(withNote), action: "strip-notes", apply: true))
        XCTAssertEqual(transformed["ok"] as? Bool, true)
        XCTAssertEqual(project.buffers["section.tex"], section)
        XCTAssertEqual(project.openFiles, ["main.tex"])
        XCTAssertEqual(project.selected, "main.tex")
        XCTAssertTrue(project.backFiles.isEmpty)
        XCTAssertEqual(editor.selectedRange(), selection)

        let prefix = "Added line.\n"
        let active = try await call(.init(operation: "replace", file: "main.tex", source: prefix + main, expectedSHA256: EditorBridge.digest(main)))
        XCTAssertEqual(active["ok"] as? Bool, true)
        XCTAssertEqual(project.buffers["main.tex"], prefix + main)
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), "cursor")
        XCTAssertEqual(project.openFiles, ["main.tex"])

        let selected = try await call(.init(operation: "select", file: "section.tex"))
        XCTAssertEqual(selected["ok"] as? Bool, true)
        XCTAssertEqual(project.openFiles, ["main.tex", "section.tex"])
    }

    func testSelectReorderAndCloseKeepUnsavedBuffers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["main.tex", "one.tex", "two.tex"] {
            try "\\documentclass{article}\n\\begin{document}Text\\end{document}".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let project = try TeXProject(root, historyEnabled: false)
        XCTAssertEqual(project.openFiles, [project.main])
        project.selected = "one.tex"; project.selected = "two.tex"; project.selected = "one.tex"
        XCTAssertEqual(project.openFiles, ["main.tex", "one.tex", "two.tex"])
        project.cycleFileTab(forward: false)
        XCTAssertEqual(project.selected, "main.tex")
        project.cycleFileTab(forward: false)
        XCTAssertEqual(project.selected, "two.tex")
        project.cycleFileTab(forward: true)
        XCTAssertEqual(project.selected, "main.tex")
        project.updateBuffer("one.tex", to: "Unsaved writing")
        project.moveFileTab("two.tex", to: "main.tex", after: false)
        XCTAssertEqual(project.openFiles, ["two.tex", "main.tex", "one.tex"])
        XCTAssertEqual(project.selected, "two.tex")
        project.closeFileTab("one.tex")
        XCTAssertEqual(project.buffers["one.tex"], "Unsaved writing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.tex").path))
        XCTAssertTrue(project.closeSelectedFileTab())
        XCTAssertEqual(project.selected, "main.tex")
        project.closeFileTab("main.tex")
        XCTAssertFalse(project.closeSelectedFileTab())
        XCTAssertEqual(project.openFiles, ["main.tex"])
        project.selected = "one.tex"
        XCTAssertEqual(project.buffers["one.tex"], "Unsaved writing")
        XCTAssertEqual(project.openFiles, ["main.tex", "one.tex"])
    }
}
