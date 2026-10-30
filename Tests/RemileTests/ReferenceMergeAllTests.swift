import XCTest
import PDFKit
import SwiftUI
@testable import Remile

final class ReferenceMergeAllTests: XCTestCase {
    private var folder: URL!
    private var repository: ReferenceRepository!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("merge-all-" + UUID().uuidString)
        repository = ReferenceRepository(root: folder).recordingHistory(ReferenceRepository.History())
    }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) } }
    private func paper(_ title: String, doi: String) -> ReferenceRecord {
        ReferenceRecord(fields: ["title": title, "doi": doi, "author": "Author, Test", "year": "2026"])
    }
    func testDuplicatesStayWithinEachLibraryEvenThroughOtherLibraryBridge() throws {
        let other = try repository.addLibrary("Other")
        let first = try repository.add([paper("First paper title", doi: "10.1000/one"), paper("Second paper title", doi: "10.1000/two")])
        _ = try repository.add([paper("Second paper title", doi: "10.1000/one")], libraryID: other.id)
        let records = try repository.records()
        XCTAssertFalse(ReferenceDuplicates.lookup(records).isEmpty)
        XCTAssertTrue(ReferenceDuplicates.withinLibraries(records).isEmpty)
        _ = try repository.add([paper("First paper title", doi: "10.1000/one")])
        let duplicates = ReferenceDuplicates.withinLibraries(try repository.records())
        XCTAssertEqual(duplicates[first[0].id]?.count, 2)
        XCTAssertNil(duplicates[first[1].id])
    }
    func testMergeAllIsOneUndoStepAndRejectsStaleGroupsAtomically() throws {
        let rows = try repository.add([paper("First paper title", doi: "10.1000/one"), paper("First paper title", doi: "10.1000/one"), paper("Second paper title", doi: "10.1000/two"), paper("Second paper title", doi: "10.1000/two")])
        let groups = [Array(rows[0..<2]), Array(rows[2..<4])]
        try repository.mergeAll(groups)
        XCTAssertEqual(try repository.records().count, 2)
        try repository.undo()
        let restored = try repository.records()
        XCTAssertEqual(restored.map(\.id), rows.map(\.id))
        XCTAssertEqual(restored.map(\.key), rows.map(\.key))
        XCTAssertEqual(restored.map(\.fields), rows.map(\.fields))
        var changed = restored[3]; changed.fields["note"] = "Local change"
        _ = try repository.update(changed, expected: changed.revision)
        let before = try repository.records()
        XCTAssertThrowsError(try repository.mergeAll([Array(restored[0..<2]), Array(restored[2..<4])]))
        XCTAssertEqual(try repository.records(), before)
        let other = try repository.addLibrary("Other")
        let foreign = try XCTUnwrap(repository.add([paper("First paper title", doi: "10.1000/one")], libraryID: other.id).first)
        XCTAssertThrowsError(try repository.mergeAll([[rows[0], foreign]]))
    }
    func testBatchRetainsRelationsRewrittenByEarlierGroups() throws {
        let rows = try repository.add([paper("First paper title", doi: "10.1000/one"), paper("First paper title", doi: "10.1000/one"), paper("Second paper title", doi: "10.1000/two"), paper("Second paper title", doi: "10.1000/two")])
        let base = try XCTUnwrap(ReferenceMergePlan.ranked(Array(rows[0..<2])).first)
        let discarded = try XCTUnwrap(rows[0..<2].first { $0.id != base.id })
        for row in rows[2..<4] {
            var changed = row; changed.fields["crossref"] = discarded.key
            _ = try repository.update(changed, expected: changed.revision)
        }
        let current = try repository.records()
        try repository.mergeAll([Array(current[0..<2]), Array(current[2..<4])])
        let kept = try repository.records()
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.first { $0.fields["doi"] == "10.1000/two" }?.fields["crossref"], base.key)
    }
    func testMergedZoteroOriginsUpdateWithoutReappearingAndKeepLockedKey() throws {
        let scope = ZoteroScope(library: ZoteroLibrary(path: "users/0", name: "My Library"))
        var a = paper("First paper title", doi: "10.1000/one"), b = a
        a.key = "local_key"; a.zotero = ZoteroReference(source: "users/0/items/AAAA1111", version: 1)
        b.key = "BBBB2222"; b.zotero = ZoteroReference(source: "users/0/items/BBBB2222", version: 1)
        let library = try repository.importZotero(scope, entries: [ZoteroImportEntry(record: a, files: []), ZoteroImportEntry(record: b, files: [])])
        var rows = try repository.records()
        rows[0].citationKeyLocked = true
        _ = try repository.update(rows[0], expected: rows[0].revision)
        rows = try repository.records()
        try repository.mergeAll([rows])
        a.fields["abstract"] = "New abstract"
        b.fields["publisher"] = "New publisher"
        _ = try repository.importZotero(scope, entries: [ZoteroImportEntry(record: a, files: []), ZoteroImportEntry(record: b, files: [])], updating: library)
        let kept = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(try repository.records().count, 1)
        XCTAssertEqual(kept.key, "local_key")
        XCTAssertEqual(kept.citationKeyLocked, true)
        XCTAssertEqual(kept.zotero?.sources.count, 2)
        XCTAssertEqual(kept.fields["publisher"], "New publisher")
        XCTAssertEqual(kept.fields["abstract"], "New abstract")
    }
    func testStrongIdentityAutomaticallySharesPDFWithoutMetadataOrKeyChanges() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("fixture.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let source = try XCTUnwrap(repository.addFetched(paper("Source title", doi: "10.1000/one"), pdf: Data(contentsOf: url), libraryID: ReferenceLibrary.primaryID))
        let library = try repository.addLibrary("Metadata")
        var local = paper("My edited title", doi: "10.1000/one"); local.key = "my_key"
        _ = try repository.add([local, paper("Source title", doi: "10.1000/different")], libraryID: library.id)
        let records = try repository.records()
        let shared = try XCTUnwrap(records.first { $0.title == "My edited title" })
        XCTAssertEqual(shared.key, "Author_2026_My")
        XCTAssertEqual(shared.attachments, source.attachments)
        XCTAssertTrue(records.first { $0.fields["doi"] == "10.1000/different" }!.attachments.isEmpty)
        let version = repository.version()
        try repository.sharePaperPDFs()
        XCTAssertEqual(repository.version(), version)
    }
    @MainActor func testCleanupSheetRendersBatchAction() async throws {
        guard let path = ProcessInfo.processInfo.environment["REMILE_MERGE_CAPTURE"] else { return }
        _ = NSApplication.shared
        _ = try repository.add([paper("A consistent formulation of turbulent flames", doi: "10.1000/one"), paper("A consistent formulation of turbulent flames", doi: "10.1000/one"), paper("A data-driven reduced-order model", doi: "10.1000/two"), paper("A data-driven reduced-order model", doi: "10.1000/two")])
        let model = ReferenceModel(repository: repository)
        model.selectLibrary(ReferenceLibrary.primaryID)
        model.load()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let host = NSHostingView(rootView: ReferenceCleanupReview(model: model))
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            _ = host.bitmapImageRepForCachingDisplay(in: host.bounds)
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent(name + "-cleanup.png"))
            window.contentView = nil
        }
    }

}
