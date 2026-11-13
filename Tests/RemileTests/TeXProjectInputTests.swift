import XCTest
@testable import Remile

final class TeXProjectInputTests: XCTestCase {
    @MainActor func testHiddenWorkspaceReleasesCompletionIndexAndRebuildsItOnDemand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"\documentclass{article}\label{eq:initial}"#
            .write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        weak var previous: TeXLocalCompletion?
        let source = #"\ref{eq:"#
        let selection = NSRange(location: source.utf16.count, length: 0)
        do {
            let index = project.localCompletion
            previous = index
            let result = await index.context(source, selection: selection, file: project.selected,
                                             paths: project.treeFiles, buffers: project.buffers)
            XCTAssertEqual(result?.items.first?.label, "eq:initial")
        }
        XCTAssertNotNil(previous)
        project.releaseEditorAssistance()
        XCTAssertNil(previous)

        let updated = #"\documentclass{article}\label{eq:updated}"#
        project.updateBuffer("main.tex", to: updated)
        let result = await project.localCompletion.context(source, selection: selection, file: project.selected,
                                                           paths: project.treeFiles, buffers: project.buffers)
        XCTAssertEqual(result?.items.first?.label, "eq:updated")
        XCTAssertEqual(project.buffers["main.tex"], updated)
    }

    @MainActor func testEditorBindingInvalidatesOnlyTheEditedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = #"\documentclass{article}"#
        try original.write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try "Another source".write(to: root.appendingPathComponent("part.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        let hashes = project.sourceHashes
        let binding = project.source
        let revision = project.editRevision
        binding.wrappedValue = original
        XCTAssertEqual(project.editRevision, revision)
        XCTAssertEqual(project.cachedSourceHashCount, 2)

        let edited = original + "\n% An edit"
        binding.wrappedValue = edited
        XCTAssertEqual(project.editRevision, revision + 1)
        XCTAssertEqual(project.cachedSourceHashCount, 1)
        XCTAssertEqual(project.sourceHashes["part.tex"], hashes["part.tex"])
        XCTAssertEqual(project.sourceHashes["main.tex"], SourceDigest.sha256(edited))
        XCTAssertTrue(project.save())
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("main.tex"), encoding: .utf8), edited)
        XCTAssertFalse(project.dirty)
    }

    @MainActor func testBuildLogSeparatesMessagesAndRevealsNestedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        let sections = root.appendingPathComponent("Sections")
        try manager.createDirectory(at: sections, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try "\\documentclass{article}".write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        let file = "Sections/Study design.tex"
        try String(repeating: "A line.\n", count: 25).write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        let log = #"""
        This is pdfTeX, Version 3
        (./main.tex
        ("./Sections/Study design.tex"
        LaTeX Font Warning: Font shape unavailable
        (Font)              size substituted on input line 7.
        Underfull \hbox (badness 10000) in paragraph at lines 12--18
        []\OT1/cmr/m/n/10 text ignored
        Overfull \vbox (4.56pt too high) has occurred while \output is active []
        )
        LaTeX Warning: Citation undefined on input line 2.
        )
        """#
        let diagnostics = TeXDiagnostics.parse(log)
        XCTAssertEqual(diagnostics.map(\.severity), [.warning, .info, .info, .warning])
        XCTAssertEqual(diagnostics.map(\.line), [7, 12, nil, 2])
        XCTAssertEqual(diagnostics.map(\.file), ["./" + file, "./" + file, "./" + file, "./main.tex"])
        XCTAssertEqual(diagnostics[0].displayMessage, "Font shape unavailable size substituted on input line 7.")
        XCTAssertFalse(diagnostics[1].message.contains("ignored"))
        XCTAssertFalse(diagnostics[2].message.contains("[]"))
        project.reveal(diagnostics[1])
        XCTAssertEqual(project.selected, file)
        XCTAssertEqual(project.sourceJump?.location.line, 11)
        project.reveal(diagnostics[2])
        XCTAssertEqual(project.sourceJump?.marksLine, false)
    }

    @MainActor func testRestoreBibliographyRequiresTheOriginalProjectFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = "\\documentclass{article}\n\\bibliographystyle{plain}\n\\bibliography{reference}\n"
        let compiled = "\\begin{thebibliography}{1}\n\\bibitem{demo} Example.\n\\end{thebibliography}"
        let embedded = try TeXSourceTools.inlineBibliography(source, bbl: compiled, keepOrigin: true)
        let main = root.appendingPathComponent("main.tex")
        let references = root.appendingPathComponent("reference.bib")
        try embedded.write(to: main, atomically: true, encoding: .utf8)
        try "@misc{demo, title={Example}}".write(to: references, atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        let edit = try TeXTools.prepare("restore-bibliography", project: project, file: "main.tex")
        XCTAssertEqual(edit.source, source)
        XCTAssertEqual(edit.references, ["reference.bib"])
        try manager.removeItem(at: references)
        XCTAssertThrowsError(try TeXTools.prepare("restore-bibliography", project: project, file: "main.tex"))
        XCTAssertEqual(project.buffers["main.tex"], embedded)
    }

    func testInputSuggestionsNarrowFromOpeningBraceAndReplaceAnExistingArgument() async throws {
        let completion = TeXLocalCompletion()
        let paths = ["code/sample.txt", "contents/0_acronyms.tex", "contents/1_introduction", "setup/settings.tex"]
        for (prefix, expected) in [("", paths), ("c", Array(paths.prefix(3))), ("co", Array(paths.prefix(3))), ("cont", Array(paths[1...2]))] {
            let text = "% Contents\n\\input{" + prefix
            let result = await completion.context(text, selection: NSRange(location: text.utf16.count, length: 0), file: "main.tex", paths: paths, buffers: [:])
            XCTAssertEqual(result?.items.map(\.label), expected)
        }
        let prefix = "\\input{contents/0_", source = prefix + "old} % keep"
        let result = await completion.context(source, selection: NSRange(location: prefix.utf16.count, length: 0), file: "main.tex", paths: paths, buffers: [:])
        let context = try XCTUnwrap(result)
        let item = try XCTUnwrap(context.items.first)
        XCTAssertEqual((source as NSString).replacingCharacters(in: context.range, with: item.insertion), "\\input{contents/0_acronyms} % keep")
    }

    func testGraphicPathsAfterOptionsAndLineBreak() async throws {
        let completion = TeXLocalCompletion()
        let prefix = "\\includegraphics[height=0.2\\textheight] % figure size\n  {figures/"
        let paths = ["figures/mesh_1.png", "figures/mesh_2.pdf", "figures/notes.tex"]
        let result = await completion.context(prefix + "}", selection: NSRange(location: prefix.utf16.count, length: 0), file: "main.tex", paths: paths, buffers: [:])
        let context = try XCTUnwrap(result)
        XCTAssertEqual(context.items.map(\.insertion), ["figures/mesh_1.png}", "figures/mesh_2.pdf}"])
        let comment = "% \\includegraphics{figures/"
        let insideComment = await completion.context(comment, selection: NSRange(location: comment.utf16.count, length: 0), file: "main.tex", paths: paths, buffers: [:])
        XCTAssertNil(insideComment)
    }

    @MainActor func testFolderDropPreservesNestedFilesAndUnsavedSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = folder.appendingPathComponent("Project"), incoming = folder.appendingPathComponent("Sections")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("contents"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        try manager.createDirectory(at: incoming.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
        try "\\documentclass{article}".write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try "Imported source".write(to: incoming.appendingPathComponent("nested/part.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        project.updateBuffer("main.tex", to: "Unsaved editing")

        await project.drop([incoming], into: "contents")
        let path = "contents/Sections/nested/part.tex"
        XCTAssertTrue(project.treeFiles.contains(path))
        XCTAssertTrue(project.treeFolders.contains("contents/Sections/nested/empty"))
        XCTAssertEqual(project.buffers[path], "Imported source")
        XCTAssertEqual(project.buffers["main.tex"], "Unsaved editing")
        XCTAssertEqual(project.fileRevision, 1)
        await project.drop([incoming], into: "contents")
        XCTAssertEqual(project.treeFiles.filter { $0 == path }.count, 1)
        XCTAssertEqual(project.fileRevision, 1)
    }
}
