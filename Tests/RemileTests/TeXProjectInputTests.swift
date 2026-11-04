import XCTest
@testable import Remile

final class TeXProjectInputTests: XCTestCase {
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
        project.buffers["main.tex"] = "Unsaved editing"

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
