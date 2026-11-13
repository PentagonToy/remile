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
    func testThumbnailReloadsWhenAttachmentContentChangesAtSameURL() async throws {
        let record = try pdfRecord()
        let attachment = try XCTUnwrap(record.attachments.first)
        let url = repository.attachmentURL(attachment)
        let renderer = ReferenceThumbnailRenderer()
        let first = try await renderer.render(url: url, digest: attachment.sha256, page: 20)
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.count, 1)
        XCTAssertGreaterThan(first.image.width, 0)

        let replacement = folder.appendingPathComponent("replacement.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(replacement as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        try Data(contentsOf: replacement).write(to: url, options: .atomic)
        let updated = try await renderer.render(url: url, digest: "replacement", page: 20)
        XCTAssertEqual(updated.index, 1)
        XCTAssertEqual(updated.count, 2)
        let previous = try await renderer.render(url: url, digest: "replacement", page: 0)
        XCTAssertEqual(previous.index, 0)
        XCTAssertEqual(previous.count, 2)
    }
    func testReferenceSearchPreservesFormattedNamesAndPhraseMatching() {
        let record = ReferenceRecord(key: "fixedkey", fields: [
            "title": "{Flame} mixing",
            "author": #"Garc{\'i}a, Ana and Doe, Jane"#,
            "abstract": "Ammonia and hydrogen combustion."
        ])
        XCTAssertTrue(record.matchesSearch(""))
        XCTAssertTrue(record.matchesSearch("FLAME"))
        XCTAssertTrue(record.matchesSearch("ammonia"))
        XCTAssertTrue(record.matchesSearch("García"))
        XCTAssertTrue(record.matchesSearch("fixedkey Flame"))
        XCTAssertFalse(record.matchesSearch("fixedkeyFlame"))
        XCTAssertFalse(record.matchesSearch("methane"))
    }

    @MainActor func testReloadWhileBusyStillVerifiesTheReaderAttachment() async throws {
        let record = try pdfRecord()
        let attachment = try XCTUnwrap(record.attachments.first)
        let url = repository.attachmentURL(attachment)
        let model = ReferenceModel(repository: repository)
        model.load()
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
        let loaded = try XCTUnwrap(model.selection)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(pdf.page(at: 0))
        page.rotation = 90
        try XCTUnwrap(pdf.dataRepresentation()).write(to: url, options: .atomic)

        model.load()
        model.readingAttachment = attachment.id
        model.load()
        let editDeadline = ContinuousClock.now + .seconds(3)
        while model.selection?.revision == loaded.revision, ContinuousClock.now < editDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.error)
        XCTAssertNil(model.readingAttachment)
        XCTAssertNotEqual(model.selection?.attachments.first?.sha256, attachment.sha256)
        XCTAssertEqual(model.selection?.id, loaded.id)
    }

    @MainActor func testReferenceSidebarTracksTrashedRecordsAndCollections() async throws {
        let library = try repository.addLibrary("Other library")
        let collection = try repository.addLibrary("Reading", parentID: library.id)
        let primary = try XCTUnwrap(repository.add([ReferenceRecord(fields: ["title": "Primary paper"])]).first)
        let papers = try repository.add([
            ReferenceRecord(fields: ["title": "Visible paper"]),
            ReferenceRecord(fields: ["title": "Trashed paper"]),
        ], libraryID: library.id)
        try repository.move(papers[0].id, to: collection.id)
        try repository.trash(papers[1].id)

        let model = ReferenceModel(repository: repository)
        func reload() async throws {
            model.load()
            let deadline = ContinuousClock.now + .seconds(3)
            while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.busy)
            XCTAssertNil(model.error)
        }
        try await reload()
        XCTAssertEqual(model.allRecords.map(\.id), [primary.id, papers[0].id])
        XCTAssertEqual(model.trashRecords.map(\.id), [papers[1].id])
        XCTAssertEqual(model.libraryCounts[library.id], 1)
        model.selectLibrary(collection.id)
        XCTAssertTrue(model.hasActiveLibraryRecords)
        XCTAssertEqual(model.items.map(\.id), [papers[0].id])
        model.query = "unmatched"
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.hasActiveLibraryRecords)
        model.query = ""

        try repository.deleteLibrary(collection.id)
        try await reload()
        XCTAssertEqual(model.allRecords.map(\.id), [primary.id])
        XCTAssertEqual(Set(model.trashRecords.map(\.id)), Set(papers.map(\.id)))
        XCTAssertNil(model.libraryCounts[library.id])
        XCTAssertTrue(model.contents(library.id).allSatisfy { $0.trashed != nil })

        try repository.restoreLibrary(collection.id)
        try await reload()
        XCTAssertEqual(model.allRecords.map(\.id), [primary.id, papers[0].id])
        XCTAssertEqual(model.trashRecords.map(\.id), [papers[1].id])
        XCTAssertEqual(model.libraryCounts[collection.id], 1)
    }

    func testCLIExportIncludesAllLibrariesAndHonoursExplicitScope() throws {
        _ = try repository.add([ReferenceRecord(fields: ["title": "First paper"])])
        let other = try repository.addLibrary("Other")
        _ = try repository.add([ReferenceRecord(fields: ["title": "Second paper"])], libraryID: other.id)
        XCTAssertEqual(try ReferenceCLI.response(["export"], repository: repository)["count"] as? Int, 2)
        XCTAssertEqual(try ReferenceCLI.response(["export", "--library", other.id.uuidString], repository: repository)["count"] as? Int, 1)
    }
    func testPDFInventoryIgnoresMetadataAndTracksRestoredOrChangedAttachments() throws {
        let original = try pdfRecord()
        let library = try repository.addLibrary("Other")
        let libraries = [ReferenceLibrary.primary, library]
        let before = ReferenceRepository.activePDFs(records: [original], libraries: libraries)
        XCTAssertEqual(before.count, 1)

        var edited = original
        edited.fields["year"] = "2026"
        edited.key = "newkey"
        XCTAssertEqual(ReferenceRepository.activePDFs(records: [edited], libraries: libraries), before)

        var linked = ReferenceRecord(libraryID: library.id)
        linked.attachments = edited.attachments
        XCTAssertEqual(ReferenceRepository.activePDFs(records: [edited, linked], libraries: libraries), before)

        edited.trashed = Date()
        var trashedLibrary = library
        trashedLibrary.trashed = Date()
        XCTAssertTrue(ReferenceRepository.activePDFs(records: [edited, linked], libraries: [.primary, trashedLibrary]).isEmpty)

        linked.attachments[0].sha256 = String(repeating: "a", count: 64)
        XCTAssertFalse(ReferenceRepository.activePDFs(records: [linked], libraries: libraries).isSubset(of: before))
    }
    func testDetachedPDFKeepsTrashCleanupAvailable() throws {
        let record = try pdfRecord()
        let attachment = try XCTUnwrap(record.attachments.first)
        let url = repository.attachmentURL(attachment)
        XCTAssertFalse(try repository.snapshot().hasPendingTrashCleanup)
        _ = try repository.removeAttachments([attachment.id], from: record.id, expected: record.revision)
        XCTAssertTrue(try repository.snapshot().hasPendingTrashCleanup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try repository.emptyTrash()
        XCTAssertFalse(try repository.snapshot().hasPendingTrashCleanup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try repository.records().map(\.id), [record.id])
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
