import XCTest
import PDFKit
import SwiftUI
@testable import Remile

final class ReferenceLinkTests: XCTestCase {
    private var folder: URL!
    private var repository: ReferenceRepository!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("reference-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        repository = ReferenceRepository(root: folder.appendingPathComponent("Library"), keyRule: .surnameYearWord)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func pdf(_ width: Double = 200) throws -> URL {
        let file = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        var box = CGRect(x: 0, y: 0, width: width, height: 300)
        let context = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        return file
    }
    private func item(_ revision: String = "one") -> RemarkableCloudItem {
        RemarkableCloudItem(id: "11111111-1111-4111-8111-111111111111", title: "Marked paper", revision: revision, fileType: "pdf")
    }
    func testLinkAndReimportPreserveTargetAndUseCurrentCloudAttachment() throws {
        repository = repository.recordingHistory(ReferenceRepository.History())
        let original = try pdf()
        let target = try XCTUnwrap(repository.importFiles([original]).first)
        let id = try repository.importRemarkable(item(), file: pdf(220), fields: ["doi": "10.1000/test"])
        let source = try XCTUnwrap(repository.records().first { $0.id == id })
        try repository.linkRemarkable(source, to: target)
        XCTAssertEqual(try repository.records().first { $0.id == id }?.linkedReferences, [target.id])
        XCTAssertEqual(try repository.records().first { $0.id == target.id }, target)
        try repository.undo()
        XCTAssertNil(try repository.records().first { $0.id == id }?.linkedReferences)
        try repository.undo(redo: true)
        _ = try repository.importRemarkable(item("two"), file: pdf(240), fields: [:])
        let updated = try XCTUnwrap(repository.records().first { $0.id == id })
        XCTAssertEqual(updated.linkedReferences, [target.id])
        XCTAssertEqual(updated.remarkable?.revision, "two")
        XCTAssertNotEqual(updated.attachments, source.attachments)
        XCTAssertEqual(try repository.records().first { $0.id == target.id }, target)
        try repository.linkRemarkable(updated, to: target, disconnect: true)
        XCTAssertNil(try repository.records().first { $0.id == id }?.linkedReferences)
        XCTAssertThrowsError(try repository.linkRemarkable(updated, to: target))
    }
    func testZoteroImportOwnsItsKeysAndSharesPDFsWithMetadataOnlyLibraries() throws {
        let local = try XCTUnwrap(repository.add([ReferenceRecord(fields: ["title": "My edited title", "doi": "10.1000/shared"]) ]).first)
        let scope = ZoteroScope(library: ZoteroLibrary(path: "users/0", name: "My Library"))
        let item = try JSONDecoder().decode(ZoteroItem.self, from: Data(#"{"key":"ABCD1234","version":1,"data":{"itemType":"journalArticle","title":"Zotero title","DOI":"10.1000/shared","date":"2026","creators":[{"creatorType":"author","lastName":"Author","firstName":"Test"}]}}"#.utf8))
        let draft = try item.reference(in: scope.library)
        let file = try pdf()
        let library = try repository.importZotero(scope, entries: [ZoteroImportEntry(record: draft, files: [file])])
        let first = try XCTUnwrap(repository.records().first { $0.library == library })
        let attached = try XCTUnwrap(repository.records().first { $0.id == local.id })
        XCTAssertEqual(first.key, "ABCD1234")
        XCTAssertEqual(attached.title, local.title)
        XCTAssertEqual(attached.key, local.key)
        XCTAssertEqual(first.attachments, attached.attachments)
        var edited = first
        edited.key = "my_custom_key"; edited.fields["title"] = "My own Zotero copy"
        edited = try repository.update(edited, expected: first.revision, renameKey: true)
        _ = try repository.importZotero(scope, entries: [ZoteroImportEntry(record: draft, files: [file])])
        XCTAssertEqual(try repository.records().first { $0.id == edited.id }, edited)
        XCTAssertEqual(try repository.records().filter { $0.library == library }.count, 2)
        XCTAssertEqual(Set(try repository.records().flatMap(\.attachments).map(\.id)).count, 1)
        _ = try repository.regenerate(id: edited.id, expected: edited.revision, libraryID: library, rule: .surnameYear)
        XCTAssertEqual(try repository.records().first { $0.id == edited.id }?.key, "Author_2026")
    }
    func testRemarkableNoteKeyAndVerifiedPromotionPreserveManualAndLockedKeys() throws {
        var cloud = item()
        cloud.createdTime = "1700000000000"
        let id = try repository.importRemarkable(cloud, file: pdf(), fields: ["doi": "10.1000/test"])
        let initial = try XCTUnwrap(repository.records().first { $0.id == id })
        XCTAssertEqual(initial.key, "note_Markedpaper_20231114")
        let metadata = ReferenceRecord(type: "article", fields: ["title": "Verified paper", "doi": "10.1000/test", "author": "Author, Test", "year": "2026"])
        let next = try ReferenceRecognition.merged(initial, with: metadata)
        try repository.applyCleanup([.init(before: initial, after: next)])
        let promoted = try XCTUnwrap(repository.records().first { $0.id == id })
        XCTAssertEqual(promoted.key, "Author_2026_Marked")
        XCTAssertEqual(ReferenceKind.classify(promoted), .article)
        var manual = promoted; manual.key = "my_key"
        manual = try repository.update(manual, expected: promoted.revision, renameKey: true)
        var changed = manual; changed.fields["year"] = "2027"
        try repository.applyCleanup([.init(before: manual, after: changed)])
        XCTAssertEqual(try repository.records().first { $0.id == id }?.key, "my_key")
        XCTAssertEqual(RemarkableCitationKey.note(title: "Fluid_Dynamics_notes.pdf", created: Date(timeIntervalSince1970: 1700000000)), "note_Fluid_20231114")
    }
    func testNoteKeyCollisionsAndLockedPromotion() throws {
        let file = try pdf()
        let firstID = try repository.importRemarkable(item(), file: file, fields: ["doi": "10.1000/test"])
        let secondItem = RemarkableCloudItem(id: "22222222-2222-4222-8222-222222222222", title: "Marked paper", revision: "one", fileType: "notebook")
        let secondID = try repository.importRemarkable(secondItem, file: file, fields: [:])
        let first = try XCTUnwrap(repository.records().first { $0.id == firstID })
        let second = try XCTUnwrap(repository.records().first { $0.id == secondID })
        XCTAssertEqual(second.key, first.key + "_2")
        try repository.setKeyLock([first], locked: true)
        let locked = try XCTUnwrap(repository.records().first { $0.id == firstID })
        let metadata = ReferenceRecord(type: "article", fields: ["title": "Verified paper", "doi": "10.1000/test", "author": "Author, Test", "year": "2026"])
        let next = try ReferenceRecognition.merged(locked, with: metadata)
        try repository.applyCleanup([.init(before: locked, after: next)])
        let promoted = try XCTUnwrap(repository.records().first { $0.id == firstID })
        XCTAssertEqual(promoted.key, locked.key)
        XCTAssertEqual(promoted.citationKeyLocked, true)
        XCTAssertEqual(ReferenceKind.classify(promoted), .article)
    }
    func testAutomaticByteIdenticalSharingSurvivesDeletingOneLibrary() throws {
        let file = try pdf()
        let native = try XCTUnwrap(repository.importFiles([file]).first)
        _ = try repository.importRemarkable(item(), file: file, fields: [:])
        let cloud = try XCTUnwrap(repository.records().first { $0.remarkable != nil })
        XCTAssertEqual(native.attachments[0].id, cloud.attachments[0].id)
        try repository.trash(native.id, expected: native.revision)
        try repository.emptyTrash()
        XCTAssertNotNil(PDFDocument(url: repository.attachmentURL(cloud.attachments[0])))
        XCTAssertEqual(try repository.records().count, 1)
    }
    func testOpeningSharedAttachmentSeparatesWritesWithoutChangingOtherReference() throws {
        let file = try pdf()
        let first = try XCTUnwrap(repository.importFiles([file]).first)
        let library = try repository.addLibrary("Other")
        let second = try XCTUnwrap(repository.importFiles([file], libraryID: library.id).first)
        XCTAssertEqual(first.attachments, second.attachments)
        let original = try Data(contentsOf: repository.attachmentURL(first.attachments[0]))
        let opened = try repository.prepareAttachment(second.attachments[0], for: second)
        XCTAssertNotEqual(opened.id, first.attachments[0].id)
        XCTAssertEqual(try Data(contentsOf: repository.attachmentURL(opened)), original)
        XCTAssertEqual(try ReferenceEvidence.attachment(recordID: second.id, attachmentID: second.attachments[0].id, repository: repository).data, original)
        let replacement = try Data(contentsOf: pdf(250))
        try replacement.write(to: repository.attachmentURL(opened), options: .atomic)
        try repository.refreshAttachment(opened.id)
        XCTAssertEqual(try Data(contentsOf: repository.attachmentURL(first.attachments[0])), original)
        XCTAssertEqual(try repository.records().first { $0.id == first.id }, first)
        XCTAssertNotEqual(try repository.records().first { $0.id == second.id }?.attachments[0].sha256, first.attachments[0].sha256)
    }
    func testSourceMatchingNeverTreatsDifferentDOIsAsExactMatches() {
        var source = ReferenceRecord(fields: ["doi": "https://doi.org/10.1000/test"])
        let target = ReferenceRecord(fields: ["doi": "10.1000/test"])
        XCTAssertEqual(ReferenceLinkMatch.reason(source, target), "Same DOI")
        source.fields["doi"] = "10.1000/other"
        XCTAssertNil(ReferenceLinkMatch.reason(source, target))
    }
    @MainActor func testAllReferencesExcludesTrashAndSearchesAcrossLibraries() async throws {
        let other = try repository.addLibrary("Other")
        _ = try repository.add([ReferenceRecord(fields: ["title": "Combustion one"])])
        _ = try repository.add([ReferenceRecord(fields: ["title": "Combustion two"])], libraryID: other.id)
        let discarded = try XCTUnwrap(repository.add([ReferenceRecord(fields: ["title": "Discarded"])]).first)
        try repository.trash(discarded.id, expected: discarded.revision)
        let model = ReferenceModel(repository: repository)
        model.load()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedLibrary, ReferenceLibrary.allID)
        model.notice = "Import complete"
        model.load()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.notice, "Import complete")
        model.query = "Combustion"
        XCTAssertEqual(model.items.count, 2)
        model.selectLibrary(other.id)
        XCTAssertEqual(model.items.count, 1)
        model.selectLibrary(ReferenceLibrary.allID)
        model.query = "Discarded"
        XCTAssertTrue(model.items.isEmpty)
    }
    func testMergingNativeDuplicatesRetainsTheRemarkableConnection() throws {
        let records = try repository.add([
            ReferenceRecord(fields: ["title": "First", "doi": "10.1000/shared"]),
            ReferenceRecord(fields: ["title": "Second", "doi": "10.1000/shared"])
        ])
        let id = try repository.importRemarkable(item(), file: pdf(), fields: [:])
        let source = try XCTUnwrap(repository.records().first { $0.id == id })
        try repository.linkRemarkable(source, to: records[1])
        try repository.merge(records, preferred: records[0].id, alignMetadata: true)
        XCTAssertEqual(try repository.records().first { $0.id == id }?.linkedReferences, [records[0].id])
    }
    func testStorageOptimisationRetainsSeparatePathsAndIndependentEdits() throws {
        let file = try pdf()
        let first = try XCTUnwrap(repository.importFiles([file]).first)
        let second = try XCTUnwrap(repository.importFiles([file]).first)
        let separate = try repository.prepareAttachment(second.attachments[0], for: second)
        let before = try repository.records()
        XCTAssertNotEqual(separate.id, first.attachments[0].id)
        XCTAssertEqual(try repository.optimisePDFs(), 1)
        XCTAssertEqual(try repository.optimisePDFs(), 0, "Unchanged files do not need another content read or clone")
        XCTAssertEqual(try repository.records(), before)
        let original = try Data(contentsOf: repository.attachmentURL(first.attachments[0]))
        try Data(contentsOf: pdf(280)).write(to: repository.attachmentURL(separate), options: .atomic)
        XCTAssertEqual(try Data(contentsOf: repository.attachmentURL(first.attachments[0])), original)
    }
    @MainActor func testConnectedBrowsersRenderInBothAppearances() async throws {
        guard let path = ProcessInfo.processInfo.environment["REMILE_LINK_CAPTURE"] else { return }
        _ = NSApplication.shared
        _ = try repository.add([ReferenceRecord(fields: ["title": "A paper in the main library"])])
        let other = try repository.addLibrary("Test library")
        _ = try repository.add([ReferenceRecord(fields: ["title": "A paper in another library"])], libraryID: other.id)
        _ = try repository.importRemarkable(item(), file: pdf(), fields: [:])
        _ = try repository.importZotero(ZoteroScope(library: ZoteroLibrary(path: "users/0", name: "My Zotero Library")), entries: [ZoteroImportEntry(record: ReferenceRecord(fields: ["title": "Imported Zotero paper"]), files: [])])
        let references = ReferenceModel(repository: repository)
        references.load()
        for _ in 0..<100 where references.busy { try await Task.sleep(for: .milliseconds(10)) }
        let zotero = ZoteroExtensionModel()
        let library = ZoteroLibrary(path: "users/0", name: "My Library")
        zotero.libraries = [library]
        zotero.collections[library.id] = [ZoteroCollection(key: "ABCD1234", name: "Research", parent: nil)]
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            func capture<V: View>(_ view: V, _ suffix: String, size: NSSize) throws {
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent(name + "-" + suffix + ".png"))
            }
            try capture(ZoteroConnection(model: zotero, references: references, showReference: {}), "zotero", size: NSSize(width: 880, height: 590))
            try capture(ReferenceWorkspace(model: references, goHome: {}), "reference", size: NSSize(width: 1100, height: 680))
        }
    }
    @MainActor func testApprovedCredentialIsReusedOnlyUntilSessionIsCleared() {
        var calls = 0
        let session = RemarkableCredentialSession { interactive in calls += 1; return interactive ? "fixture" : nil }
        XCTAssertNil(session.read())
        XCTAssertEqual(session.read(interactive: true), "fixture")
        XCTAssertEqual(session.read(), "fixture")
        XCTAssertEqual(calls, 2)
        session.clear()
        XCTAssertNil(session.read())
        XCTAssertEqual(calls, 3)
    }
}
