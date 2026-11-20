import CoreText
import PDFKit
import SQLite3
import XCTest
@testable import Remile

final class SearchIndexUpdateTests: XCTestCase {
    private actor ProgressLog {
        var values: [LibraryProgress] = []
        func append(_ value: LibraryProgress) { values.append(value) }
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func pdf(_ url: URL, text: String) throws {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        let line = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)])
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        context.endPDFPage()
        context.closePDF()
    }

    private func refresh(_ index: LibraryIndex, folderID: String? = nil, force: Bool = false) async throws -> [LibraryProgress] {
        let log = ProgressLog()
        try await index.refresh(folderID: folderID, force: force) { await log.append($0) }
        return await log.values
    }

    private func pageIDs(_ database: URL) throws -> [String: Int64] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var rows: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT path,rowid FROM pages", -1, &rows, nil), SQLITE_OK)
        defer { sqlite3_finalize(rows) }
        var ids: [String: Int64] = [:]
        while sqlite3_step(rows) == SQLITE_ROW {
            ids[String(cString: sqlite3_column_text(rows, 0))] = sqlite3_column_int64(rows, 1)
        }
        return ids
    }

    func testAddingPDFOnlyIndexesTheNewFileAndPreservesExistingPages() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let first = documents.appendingPathComponent("a.pdf"), second = documents.appendingPathComponent("b.pdf")
        try pdf(first, text: "Hydrogen combustion in the original paper.")
        try pdf(second, text: "Pressure measurements from the second paper.")
        let database = root.appendingPathComponent("index.sqlite"), index = LibraryIndex(location: database)
        try await index.add(documents)
        _ = try await refresh(index)
        let before = try await index.snapshot(), ids = try pageIDs(database)
        let firstBytes = try Data(contentsOf: first)

        let added = documents.appendingPathComponent("c.pdf")
        try pdf(added, text: "Ammonia combustion in the added paper.")
        let progress = try await refresh(index).filter { !$0.preparingSearch && $0.total > 0 }
        XCTAssertEqual(Set(progress.map(\.name)), [added.lastPathComponent])
        XCTAssertTrue(progress.allSatisfy { $0.total == 1 })
        XCTAssertEqual(progress.last?.completed, 1)
        let after = try await index.snapshot(), updatedIDs = try pageIDs(database)
        XCTAssertEqual(after.summary.documents, 3)
        XCTAssertEqual(after.generation, before.generation + 1, "Only the new document changes the index generation")
        XCTAssertEqual(updatedIDs[first.path], ids[first.path])
        XCTAssertEqual(updatedIDs[second.path], ids[second.path])
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        let hits = try await index.rankedSearch("ammonia")
        XCTAssertTrue(hits.contains { $0.path == added.path })

        let reopened = LibraryIndex(location: database)
        let unchanged = try await refresh(reopened)
        XCTAssertFalse(unchanged.contains { !$0.preparingSearch && $0.total > 0 })
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored.generation, after.generation)
        let preparation = await reopened.lastRankerPreparation
        XCTAssertEqual(preparation, "disk", "Unchanged refresh after relaunch reuses the prepared search cache")
    }

    func testChangesFailuresAndDeletionsAreStillUpdated() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let edited = documents.appendingPathComponent("edited.pdf"), broken = documents.appendingPathComponent("broken.pdf")
        let removed = documents.appendingPathComponent("removed.pdf")
        try pdf(edited, text: "Hydrogen baseline.")
        try pdf(removed, text: "Obsolete document.")
        try Data("Not a PDF".utf8).write(to: broken)
        let index = LibraryIndex(location: root.appendingPathComponent("index.sqlite"))
        try await index.add(documents)
        _ = try await refresh(index)
        try pdf(edited, text: "Ammonia replaces the previous hydrogen baseline.")
        try FileManager.default.removeItem(at: removed)
        let progress = try await refresh(index).filter { !$0.preparingSearch && $0.total > 0 }
        XCTAssertTrue(progress.allSatisfy { $0.total == 2 })
        let summary = try await index.summary()
        XCTAssertEqual(summary.documents, 2)
        XCTAssertEqual(summary.failed, 1)
        let obsolete = try await index.rankedSearch("obsolete")
        XCTAssertFalse(obsolete.contains { $0.path == removed.path })
        let changed = try await index.rankedSearch("ammonia")
        XCTAssertTrue(changed.contains { $0.path == edited.path })
    }

    func testAddingFolderDoesNotScanAnExistingUnavailableFolder() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try pdf(first.appendingPathComponent("first.pdf"), text: "First combustion paper.")
        try pdf(second.appendingPathComponent("second.pdf"), text: "Second ammonia paper.")
        let index = LibraryIndex(location: root.appendingPathComponent("index.sqlite"))
        try await index.add(first)
        _ = try await refresh(index)
        try FileManager.default.removeItem(at: first)
        let added = try await index.add(second)
        _ = try await refresh(index, folderID: added)
        let summary = try await index.summary()
        XCTAssertEqual(summary.documents, 2, "Adding a folder preserves other folders' cached documents")
        let hits = try await index.rankedSearch("ammonia")
        XCTAssertTrue(hits.contains { $0.path.hasPrefix(second.path + "/") })
    }

    func testExplicitRebuildStillProcessesUnchangedFiles() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try pdf(documents.appendingPathComponent("same.pdf"), text: "Combustion unchanged.")
        let index = LibraryIndex(location: root.appendingPathComponent("index.sqlite"))
        let id = try await index.add(documents)
        _ = try await refresh(index)
        let before = try await index.snapshot()
        let progress = try await refresh(index, folderID: id, force: true)
        XCTAssertTrue(progress.contains { !$0.preparingSearch && $0.total == 1 })
        let after = try await index.snapshot()
        XCTAssertEqual(after.generation, before.generation + 1)
    }
}
