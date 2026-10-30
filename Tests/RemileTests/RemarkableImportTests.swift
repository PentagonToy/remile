import AppKit
import PDFKit
import XCTest

@testable import Remile

final class RemarkableImportTests: XCTestCase {
    private var folder: URL!
    private var repository: ReferenceRepository!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("remarkable-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        repository = ReferenceRepository(root: folder.appendingPathComponent("Library"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func pdf(_ width: Double = 200) throws -> URL {
        let file = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        var bounds = CGRect(x: 0, y: 0, width: width, height: 300)
        let context = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return file
    }
    private func item(_ type: String = "notebook", revision: String = "one") -> RemarkableCloudItem {
        RemarkableCloudItem(
            id: "11111111-1111-4111-8111-111111111111", title: "Selected note", revision: revision, fileType: type)
    }
    func testExplicitImportCreatesNormalLibraryNoteAndManagedFirstPage() throws {
        let id = try repository.importRemarkable(item(), file: pdf(), fields: [:])
        let records = try repository.records()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(ReferenceKind.classify(record), .note)
        XCTAssertEqual(record.attachments.count, 1)
        let library = try XCTUnwrap(repository.libraries().first { $0.source == "remarkable" })
        XCTAssertEqual(record.library, library.id)
        let document = try XCTUnwrap(PDFDocument(url: repository.attachmentURL(record.attachments[0])))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertNotNil(document.page(at: 0)?.thumbnail(of: NSSize(width: 150, height: 160), for: .cropBox))
    }
    func testReimportReplacesOnlyCloudAttachmentAndPreservesEdits() throws {
        _ = try repository.importRemarkable(item(), file: pdf(), fields: [:])
        var before = try XCTUnwrap(repository.records().first)
        before.fields["title"] = "My edited title"
        before.fields["author"] = "My author"
        before.citationKeyLocked = true
        before = try repository.update(before, expected: before.revision)
        let oldAttachment = before.attachments[0]
        _ = try repository.importRemarkable(item(revision: "two"), file: pdf(250), fields: ["author": "Other author"])
        let after = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.key, before.key)
        XCTAssertEqual(after.title, "My edited title")
        XCTAssertEqual(after.authors, "My author")
        XCTAssertEqual(after.citationKeyLocked, true)
        XCTAssertEqual(after.attachments.count, 1)
        XCTAssertNotEqual(after.attachments[0].id, oldAttachment.id)
        XCTAssertEqual(after.remarkable?.revision, "two")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.attachmentURL(oldAttachment).path))
    }
    func testExplicitReimportCanUndoAndRedoThePreviousAttachment() throws {
        let history = ReferenceRepository.History()
        repository = repository.recordingHistory(history)
        _ = try repository.importRemarkable(item(), file: pdf(), fields: [:])
        let original = try XCTUnwrap(repository.records().first)
        _ = try repository.importRemarkable(item(revision: "two"), file: pdf(260), fields: [:])
        let replacement = try XCTUnwrap(repository.records().first)
        try repository.undo()
        let restored = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(restored.attachments, original.attachments)
        XCTAssertNotNil(PDFDocument(url: repository.attachmentURL(restored.attachments[0])))
        try repository.undo(redo: true)
        XCTAssertEqual(try repository.records().first?.attachments, replacement.attachments)
    }
    func testIdenticalImportDoesNotRewriteCatalogue() throws {
        let file = try pdf()
        _ = try repository.importRemarkable(item(), file: file, fields: [:])
        let version = repository.version()
        _ = try repository.importRemarkable(item(), file: file, fields: [:])
        XCTAssertEqual(repository.version(), version)
        XCTAssertEqual(try repository.records().count, 1)
    }
    func testPDFStaysNoteUntilVerifiedIdentifierMetadataMatches() throws {
        _ = try repository.importRemarkable(item("pdf"), file: pdf(), fields: ["doi": "10.1000/test"])
        let note = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(ReferenceKind.classify(note), .note)
        XCTAssertTrue(ReferenceRecognition.automaticEligible(note))
        let conference = ReferenceRecord(
            type: "inproceedings",
            fields: ["title": "Verified paper", "author": "Test Author", "year": "2026", "doi": "10.1000/test"])
        let matched = try ReferenceRecognition.merged(note, with: conference)
        XCTAssertEqual(ReferenceKind.classify(matched), .conference)
        XCTAssertEqual(matched.remarkable, note.remarkable)
        let unknown = ReferenceRecord(type: "misc", fields: conference.fields)
        XCTAssertEqual(ReferenceKind.classify(try ReferenceRecognition.merged(note, with: unknown)), .note)
        var wrong = conference
        wrong.fields["doi"] = "10.1000/wrong"
        XCTAssertThrowsError(try ReferenceRecognition.merged(note, with: wrong))
    }
    func testPDFTitleCanBeRecognisedWithoutTreatingNotebooksAsPapers() throws {
        let title = "A precise synthetic paper title for matching"
        _ = try repository.importRemarkable(item("pdf"), file: pdf(), fields: ["title": title])
        let note = try XCTUnwrap(repository.records().first)
        XCTAssertTrue(ReferenceRecognition.automaticEligible(note))
        let fetched = ReferenceRecord(type: "article", fields: ["title": title, "doi": "10.1000/example", "year": "2026"])
        XCTAssertEqual(ReferenceKind.classify(try ReferenceRecognition.merged(note, with: fetched)), .article)
        var wrong = fetched
        wrong.fields["title"] = "An unrelated paper with a similar sounding name"
        XCTAssertThrowsError(try ReferenceRecognition.merged(note, with: wrong))
        var notebook = note
        notebook.remarkable?.fileType = "notebook"
        XCTAssertFalse(ReferenceRecognition.automaticEligible(notebook))
    }
    func testProductionTitleIsReplacedButEditedTitlesStay() throws {
        XCTAssertTrue(ReferencePDFMetadata.placeholderTitle("DCE_2500001 1..18"))
        let file = try pdf()
        _ = try repository.importRemarkable(item("pdf"), file: file, fields: ["title": "DCE_2500001 1..18"])
        var old = try XCTUnwrap(repository.records().first)
        old.fields["title"] = "DCE_2500001 1..18"
        _ = try repository.update(old, expected: old.revision)
        _ = try repository.importRemarkable(item("pdf", revision: "two"), file: file, fields: ["title": "Hydrogen reaction rate modelling for large eddy simulation"])
        let corrected = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(corrected.title, "Hydrogen reaction rate modelling for large eddy simulation")
        var edited = corrected
        edited.fields["title"] = "My carefully edited title"
        edited = try repository.update(edited, expected: corrected.revision)
        _ = try repository.importRemarkable(item("pdf", revision: "three"), file: file, fields: ["title": "Another extracted title"])
        XCTAssertEqual(try repository.records().first?.title, edited.title)
    }
    func testExactPublicTitleLookupWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REMILE_TITLE_LOOKUP"] == "1" else {
            throw XCTSkip("Explicit public metadata lookup only.")
        }
        for title in [
            "Systematic Definition of Progress Variables and Intrinsically Low-Dimensional, Flamelet Generated Manifolds for Chemistry Tabulation",
            "Hydrogen reaction rate modeling based on convolutional neural network for large eddy simulation",
        ] {
            let record = ReferenceRecord(type: "unpublished", fields: ["entrysubtype": "note", "title": title])
            let fetched = try await ReferencePaperLookup.metadata(for: record)
            XCTAssertTrue(ReferencePaperLookup.matches(record, fields: fetched.fields))
            XCTAssertFalse((fetched.fields["doi"] ?? "").isEmpty)
            XCTAssertEqual(ReferenceKind.classify(fetched), .article)
        }
    }
    func testUnreadablePDFDoesNotCreateCloudRecordsOrLibrary() throws {
        let file = folder.appendingPathComponent("bad.pdf")
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try repository.importRemarkable(item(), file: file, fields: [:]))
        XCTAssertTrue(try repository.records().isEmpty)
        XCTAssertFalse(try repository.libraries().contains { $0.source == "remarkable" })
    }
    func testLocalThesisEvidencePromotesPDFWithoutChangingManualKeysOrNotebooks() throws {
        let fields = ["title": "A synthetic thesis title", "type": "Master's thesis", "author": "Example, A.", "year": "2021"]
        let file = try pdf()
        _ = try repository.importRemarkable(item("pdf"), file: file, fields: fields)
        var thesis = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(ReferenceKind.classify(thesis), .mastersThesis)
        XCTAssertFalse(thesis.key.hasPrefix("note_"))
        thesis.key = "MyManualKey"
        thesis.citationKeyLocked = true
        thesis = try repository.update(thesis, expected: thesis.revision, renameKey: true)
        _ = try repository.importRemarkable(item("pdf", revision: "two"), file: file, fields: ["type": "PhD dissertation"])
        let retained = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(retained.key, "MyManualKey")
        XCTAssertEqual(ReferenceKind.classify(retained), .mastersThesis)
        let notebook = RemarkableCloudItem(id: UUID().uuidString, title: "Notebook", revision: "one", fileType: "notebook")
        let id = try repository.importRemarkable(notebook, file: file, fields: fields)
        XCTAssertEqual(ReferenceKind.classify(try XCTUnwrap(repository.records().first { $0.id == id })), .note)
    }
}
