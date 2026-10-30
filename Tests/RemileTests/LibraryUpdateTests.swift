import XCTest
import PDFKit
@testable import Remile

final class LibraryUpdateTests: XCTestCase {
    private var folder: URL!
    private var repository: ReferenceRepository!
    private let scope = ZoteroScope(library: ZoteroLibrary(path: "users/0", name: "My Library"))
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        repository = ReferenceRepository(root: folder.appendingPathComponent("Library"), keyRule: .surnameYearWord)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func pdf(_ width: Double) throws -> URL {
        let file = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        var box = CGRect(x: 0, y: 0, width: width, height: 300)
        let context = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        return file
    }
    private func entry(key: String = "ABCD1234", version: Int = 1, file: URL? = nil, abstract: String = "") throws -> ZoteroImportEntry {
        let data: [String: Any] = ["key": key, "version": version, "data": ["itemType": "journalArticle", "title": "The remote paper", "date": "2026", "abstractNote": abstract, "creators": [["creatorType": "author", "lastName": "Author"]]]]
        let item = try JSONDecoder().decode(ZoteroItem.self, from: JSONSerialization.data(withJSONObject: data))
        return ZoteroImportEntry(record: try item.reference(in: scope.library), files: file.map { [$0] } ?? [], fileKeys: file == nil ? [] : ["PDFKEY01"], fileVersions: file == nil ? [] : [version])
    }
    func testUpdateFillsOnlyMissingFieldsRetainsLocalKeyAndAddsNewSourceItems() throws {
        let first = try entry(file: pdf(200))
        let library = try repository.importZotero(scope, entries: [first])
        var local = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(local.key, "ABCD1234")
        local.key = "my_key"; local.citationKeyLocked = true; local.fields["title"] = "My title"
        local.fields.removeValue(forKey: "zoterosource")
        local = try repository.update(local, expected: local.revision, renameKey: true)
        let changed = try entry(version: 2, file: pdf(240), abstract: "New abstract")
        let added = try entry(key: "NEWB5678")
        _ = try repository.importZotero(scope, entries: [changed, added], updating: library)
        let current = try XCTUnwrap(repository.records().first { $0.id == local.id })
        XCTAssertEqual(current.title, "My title")
        XCTAssertEqual(current.key, "my_key")
        XCTAssertEqual(current.citationKeyLocked, true)
        XCTAssertEqual(current.fields["abstract"], "New abstract")
        XCTAssertEqual(current.attachments.count, 1)
        XCTAssertNotEqual(current.attachments[0].sha256, local.attachments[0].sha256)
        XCTAssertEqual(try repository.records().count, 2)
        let fresh = try XCTUnwrap(repository.records().first { $0.id != local.id })
        XCTAssertEqual(fresh.key, "NEWB5678")
        let version = repository.version()
        _ = try repository.importZotero(scope, entries: [changed, added], updating: library)
        XCTAssertEqual(repository.version(), version)
        _ = try repository.regenerate(id: fresh.id, expected: fresh.revision, libraryID: library, rule: .surnameYearWord)
        XCTAssertEqual(try repository.records().first { $0.id == fresh.id }?.key, "Author_2026_remote")
        _ = try repository.importZotero(scope, entries: [changed, added], updating: library)
        XCTAssertEqual(try repository.records().first { $0.id == fresh.id }?.key, "Author_2026_remote")
    }
    func testLocalPDFEditsStayBesideAnUpdatedRemotePDF() throws {
        let library = try repository.importZotero(scope, entries: [entry(file: pdf(200))])
        let original = try XCTUnwrap(repository.records().first)
        let localData = try Data(contentsOf: pdf(210))
        try localData.write(to: repository.attachmentURL(original.attachments[0]), options: .atomic)
        try repository.refreshAttachment(original.attachments[0].id)
        _ = try repository.importZotero(scope, entries: [entry(version: 2, file: pdf(240))], updating: library)
        let current = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(current.attachments.count, 2)
        XCTAssertEqual(try Data(contentsOf: repository.attachmentURL(original.attachments[0])), localData)
    }
    func testUpdateRetainsLocalTrashAndUpstreamRemovalsDoNotDeleteLocalRecords() throws {
        let library = try repository.importZotero(scope, entries: [entry(), entry(key: "NEWB5678")])
        let removed = try XCTUnwrap(repository.records().first)
        try repository.trash(removed.id, expected: removed.revision)
        _ = try repository.importZotero(scope, entries: [entry(), entry(key: "NEWB5678")], updating: library)
        XCTAssertEqual(try repository.records().count, 2)
        XCTAssertNotNil(try repository.records().first { $0.id == removed.id }?.trashed)
        _ = try repository.importZotero(scope, entries: [], updating: library)
        XCTAssertEqual(try repository.records().count, 2)
    }
    func testFailedUpdateRollsBackMetadataAndNewPDFs() throws {
        let library = try repository.importZotero(scope, entries: [entry(file: pdf(200))])
        let before = try repository.records()
        let oldFiles = try FileManager.default.contentsOfDirectory(atPath: repository.root.appendingPathComponent("Attachments").path)
        let invalid = folder.appendingPathComponent("invalid.pdf")
        try Data("invalid".utf8).write(to: invalid)
        XCTAssertThrowsError(try repository.importZotero(scope, entries: [entry(version: 2, file: pdf(240)), entry(key: "NEWB5678", file: invalid)], updating: library))
        XCTAssertEqual(try repository.records(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.root.appendingPathComponent("Attachments").path).sorted(), oldFiles.sorted())
    }
    func testRemarkableUpdatePreservesLocalInkAndKey() throws {
        let cloud = RemarkableCloudItem(id: "11111111-1111-4111-8111-111111111111", title: "Notes", revision: "one", fileType: "notebook")
        let id = try repository.importRemarkable(cloud, file: pdf(200), fields: [:])
        var local = try XCTUnwrap(repository.records().first)
        local.key = "my_notes"
        local = try repository.update(local, expected: local.revision, renameKey: true)
        let ink = try Data(contentsOf: pdf(210))
        try ink.write(to: repository.attachmentURL(local.attachments[0]), options: .atomic)
        try repository.refreshAttachment(local.attachments[0].id)
        let remote = RemarkableCloudItem(id: cloud.id, title: cloud.title, revision: "two", fileType: "notebook")
        _ = try repository.importRemarkable(remote, file: pdf(240), fields: [:])
        let current = try XCTUnwrap(repository.records().first { $0.id == id })
        XCTAssertEqual(current.key, "my_notes")
        XCTAssertEqual(current.attachments.count, 2)
        XCTAssertEqual(current.remarkable?.revision, "two")
        XCTAssertEqual(try Data(contentsOf: repository.attachmentURL(local.attachments[0])), ink)
    }
    func testTitleWordsSkipArticlesWithoutBreakingLatinPhrases() {
        func record(_ title: String) -> ReferenceRecord { ReferenceRecord(fields: ["title": title, "author": "Chen, Z.", "year": "2018"]) }
        XCTAssertEqual(ReferenceKeyRule.surnameYearWord.key(for: record("A numerical investigation")), "Chen_2018_numerical")
        XCTAssertEqual(ReferenceKeyRule.surnameYearTwoWords.key(for: record("The numerical investigation")), "Chen_2018_numerical_investigation")
        XCTAssertEqual(ReferenceKeyRule.surnameYearWord.key(for: record("An introduction")), "Chen_2018_introduction")
        XCTAssertEqual(ReferenceKeyRule.surnameYearWord.key(for: record("A Priori Investigation")), "Chen_2018_APriori")
        XCTAssertEqual(ReferenceKeyRule.surnameYearTwoWords.key(for: record("A Posteriori Analysis")), "Chen_2018_APosteriori_Analysis")
    }
}
