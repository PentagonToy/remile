import XCTest
@testable import Remile
final class ZoteroCitationTests: XCTestCase {
    @MainActor func testConnectedCitationUsesTheExistingTeXProjectBibliographyPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("\\documentclass{article}\n\\begin{document}Text\\end{document}".utf8).write(to: root.appendingPathComponent("main.tex"))
        let item = try JSONDecoder().decode(ZoteroItem.self, from: Data(#"{"key":"ABCD1234","version":1,"data":{"itemType":"book","title":"Connected book"}}"#.utf8))
        let record = try ZoteroCitationSources.citationRecord(item, scope: ZoteroScope(library: ZoteroLibrary(path: "users/0", name: "My Library")))
        let project = try TeXProject(root, historyEnabled: false)
        try project.addReference(record, bibliography: "remile-references.bib")
        let source = try XCTUnwrap(project.buffers["remile-references.bib"])
        XCTAssertEqual(try ReferenceBibTeX.parse(source).first?.citationKey, record.citationKey)
        try project.addReference(record, bibliography: "remile-references.bib")
        XCTAssertEqual(project.buffers["remile-references.bib"], source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("remile-references.bib").path))
    }
    func testTypingCiteOffersAConnectedReferenceThroughExistingCompletion() throws {
        let item = try JSONDecoder().decode(ZoteroItem.self, from: Data(#"{"key":"ABCD1234","version":1,"data":{"itemType":"book","title":"Connected book"}}"#.utf8))
        let record = try ZoteroCitationSources.citationRecord(item, scope: ZoteroScope(library: ZoteroLibrary(path: "users/0", name: "My Library")))
        let source = "\\cite{con"
        let prefix = try XCTUnwrap(ReferenceCitationCompletion.prefix(source, selection: NSRange(location: (source as NSString).length, length: 0)))
        let suggestions = ReferenceCitationCompletion.suggestions(query: prefix.query, project: [], library: [record])
        XCTAssertEqual(suggestions.first?.record.citationKey, record.citationKey)
        XCTAssertEqual(prefix.closing, "}")
        XCTAssertEqual(ZoteroCitationSources.origin(suggestions[0].record), "Zotero · My Library")
    }
    func testConnectedRecordUsesStableIdentityAndProjectBibliography() throws {
        func item(_ title: String) throws -> ZoteroItem {
            let source = "{\"key\":\"ABCD1234\",\"version\":1,\"data\":{\"itemType\":\"book\",\"title\":\"" + title + "\"}}"
            return try JSONDecoder().decode(ZoteroItem.self, from: Data(source.utf8))
        }
        let library = ZoteroLibrary(path: "users/0", name: "My Library")
        let scope = ZoteroScope(library: library)
        let first = try ZoteroCitationSources.citationRecord(item("Original title"), scope: scope)
        let later = try ZoteroCitationSources.citationRecord(item("Updated title"), scope: scope)
        XCTAssertEqual(ZoteroCitationSources.origin(first), "Zotero · My Library")
        XCTAssertNil(ZoteroCitationSources.origin(ReferenceRecord()))
        XCTAssertEqual(first.id, later.id)
        XCTAssertEqual(first.citationKey, later.citationKey)
        let bib = try ReferenceCitation.appending(first, to: "")
        XCTAssertEqual(try ReferenceCitation.appending(later, to: bib), bib)
        XCTAssertEqual(try ReferenceCitation.text(first, format: .latex), "\\cite{" + first.citationKey + "}")
        XCTAssertTrue(bib.contains("Original title"))
        var collision = later; collision.fields["zoterosource"] = "groups/42/items/ABCD1234"
        XCTAssertThrowsError(try ReferenceCitation.appending(collision, to: bib))
    }
}
