import Foundation
import XCTest
@testable import Remile

final class EditorSourceReadTests: XCTestCase {
    func testProjectListsTreeAndPrefersUnsavedSources() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("sections")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data(#"\documentclass{article}"#.utf8).write(to: root.appendingPathComponent("main.tex"))
        try Data("Saved".utf8).write(to: nested.appendingPathComponent("methods.tex"))
        try Data([1, 2, 3]).write(to: nested.appendingPathComponent("figure.pdf"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.tex"),
                                                   withDestinationURL: root.appendingPathComponent("main.tex"))
        let draft = "Unsaved 본문"
        let result = try EditorSourceRead.project(root: root, file: nil, buffers: ["sections/methods.tex": draft])
        XCTAssertEqual(result["root"] as? String, root.path)
        XCTAssertEqual(result["main"] as? String, "main.tex")
        XCTAssertEqual(result["files"] as? [String], ["main.tex", "sections/figure.pdf", "sections/methods.tex"])
        XCTAssertEqual(result["folders"] as? [String], ["sections"])
        let sources = try XCTUnwrap(result["sources"] as? [String: [String: String]])
        XCTAssertEqual(sources["main.tex"]?["origin"], "disk")
        XCTAssertEqual(sources["sections/methods.tex"], [
            "source": draft, "origin": "editor-buffer", "sha256": SourceDigest.sha256(draft),
        ])
        XCTAssertNil(sources["sections/figure.pdf"])
        let single = try EditorSourceRead.project(root: root, file: "sections/methods.tex")
        XCTAssertEqual((single["sources"] as? [String: [String: String]])?.keys.sorted(), ["sections/methods.tex"])
        XCTAssertEqual(single["files"] as? [String], result["files"] as? [String])
        XCTAssertThrowsError(try EditorSourceRead.project(root: root, file: "alias.tex"))
    }

    func testMarkdownReadFromBookmark() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        try Data("Saved\n".utf8).write(to: file)
        let store = root.appendingPathComponent("ids")
        let id = try LocalDocumentIDs.register(file, kind: .markdown, directory: store)
        let document = try LocalDocumentIDs.resolve(id, directory: store)
        let saved = try EditorSourceRead.local(id: id, url: document.url, kind: document.kind, file: nil)
        let draft = try EditorSourceRead.local(id: id, url: document.url, kind: document.kind, file: nil, markdown: "", dirty: true)
        XCTAssertEqual((saved["sources"] as? [String: [String: String]])?["notes.md"]?["source"], "Saved\n")
        XCTAssertEqual((draft["sources"] as? [String: [String: String]])?["notes.md"]?["source"], "")
        XCTAssertEqual(draft["dirty"] as? Bool, true)
    }

    func testSavedOverleafProjectDoesNotRequireRemoteAccess() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = OverleafConnection(id: UUID(), projectID: "0123456789abcdef01234567",
                                         name: "Sample", account: "Fixture", branch: "main")
        let root = OverleafLibrary.projectRoot(project, directory: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Offline source".utf8).write(to: root.appendingPathComponent("main.tex"))
        try JSONEncoder().encode([project]).write(to: directory.appendingPathComponent("projects.json"))
        let result = try OverleafCommands.readSaved(id: OverleafProjectID.reference(project.projectID),
                                                    connectionID: nil, file: nil, directory: directory)
        XCTAssertEqual(result["remoteFreshness"] as? String, "not-checked")
        XCTAssertEqual(result["root"] as? String, root.path)
        XCTAssertEqual(result["files"] as? [String], ["main.tex"])
        XCTAssertEqual((result["sources"] as? [String: [String: String]])?["main.tex"]?["source"], "Offline source")
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
