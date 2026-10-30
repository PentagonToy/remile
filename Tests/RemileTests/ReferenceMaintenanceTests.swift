import XCTest
import PDFKit
@testable import Remile

final class ReferenceMaintenanceTests: XCTestCase {
    private var folder: URL!
    private var repository: ReferenceRepository!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        repository = ReferenceRepository(root: folder.appendingPathComponent("Library"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func pdfRecord() throws -> ReferenceRecord {
        let url = folder.appendingPathComponent("paper.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        return try repository.addFetched(ReferenceRecord(fields: ["title": "A paper", "doi": "10.1000/paper"]), pdf: Data(contentsOf: url), libraryID: ReferenceLibrary.primaryID)
    }
    func testCLIExportIncludesAllLibrariesAndHonoursExplicitScope() throws {
        _ = try repository.add([ReferenceRecord(fields: ["title": "First paper"])])
        let other = try repository.addLibrary("Other")
        _ = try repository.add([ReferenceRecord(fields: ["title": "Second paper"])], libraryID: other.id)
        XCTAssertEqual(try ReferenceCLI.response(["export"], repository: repository)["count"] as? Int, 2)
        XCTAssertEqual(try ReferenceCLI.response(["export", "--library", other.id.uuidString], repository: repository)["count"] as? Int, 1)
    }
    func testCLIImportReturnsStoredRevisionAfterAutomaticPDFLinking() throws {
        let source = try pdfRecord()
        let bib = folder.appendingPathComponent("metadata.bib")
        try "@article{Local, title={My title}, doi={10.1000/paper}}".write(to: bib, atomically: true, encoding: .utf8)
        let reply = try ReferenceCLI.response(["import", "--library", ReferenceLibrary.primaryID.uuidString, "--source-file", bib.path], repository: repository)
        let rows = try XCTUnwrap(reply["references"] as? [[String: String]])
        let row = try XCTUnwrap(rows.first)
        let saved = try XCTUnwrap(repository.records().first { $0.id.uuidString == row["id"] })
        XCTAssertEqual(row["revision"], saved.revision.uuidString)
        XCTAssertEqual(saved.attachments, source.attachments)
    }
    func testExplicitNoteDisconnectSurvivesAutomaticMatching() throws {
        let original = try pdfRecord()
        let target = try repository.add([ReferenceRecord(fields: ["title": "Metadata only", "doi": "10.1000/paper"])])[0]
        let attached = try XCTUnwrap(repository.records().first { $0.id == target.id })
        _ = try repository.removeAttachments(Set(attached.attachments.map(\.id)), from: attached.id, expected: attached.revision)
        let item = RemarkableCloudItem(id: "11111111-1111-4111-8111-111111111111", title: "Notes", revision: "one", fileType: "pdf")
        let id = try repository.importRemarkable(item, file: repository.attachmentURL(original.attachments[0]), fields: ["doi": "10.1000/paper"])
        var source = try XCTUnwrap(repository.records().first { $0.id == id })
        XCTAssertTrue(source.linkedReferences?.contains(target.id) == true)
        let current = try XCTUnwrap(repository.records().first { $0.id == target.id })
        try repository.linkRemarkable(source, to: current)
        source = try XCTUnwrap(repository.records().first { $0.id == id })
        try repository.linkRemarkable(source, to: current, disconnect: true)
        try repository.sharePaperPDFs()
        source = try XCTUnwrap(repository.records().first { $0.id == id })
        XCTAssertFalse(source.linkedReferences?.contains(target.id) == true)
        try repository.linkRemarkable(source, to: current)
        XCTAssertTrue(try repository.records().first { $0.id == id }!.linkedReferences!.contains(target.id))
    }
    func testManualDetachSurvivesReloadMetadataEditsAndZoteroImport() throws {
        let source = try pdfRecord()
        let destination = try repository.addLibrary("Metadata")
        _ = try repository.add([ReferenceRecord(fields: ["title": "Local title", "doi": "10.1000/paper"])], libraryID: destination.id)
        let local = try XCTUnwrap(repository.records().first { $0.library == destination.id })
        _ = try repository.removeAttachments(Set(local.attachments.map(\.id)), from: local.id, expected: local.revision)
        try repository.sharePaperPDFs()
        var current = try XCTUnwrap(repository.records().first { $0.id == local.id })
        XCTAssertTrue(current.attachments.isEmpty)
        current.fields["year"] = "2026"
        _ = try repository.update(current, expected: current.revision)
        let scope = ZoteroScope(library: ZoteroLibrary(path: "users/0", name: "My Library"))
        _ = try repository.importZotero(scope, entries: [ZoteroImportEntry(record: source, files: [repository.attachmentURL(source.attachments[0])])])
        XCTAssertTrue(try repository.records().first { $0.id == local.id }!.attachments.isEmpty)
        try repository.sharePaperPDFs()
        XCTAssertTrue(try repository.records().first { $0.id == local.id }!.attachments.isEmpty)
    }
}
