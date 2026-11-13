import CryptoKit
import XCTest
import PDFKit
@testable import Remile

@MainActor final class SearchResultRevealTests: XCTestCase {
    func testSearchPresentationFollowsOrderFilterAndUpdatedHits() {
        let first = LibraryHit(path: "/tmp/a.pdf", folderID: "fixture", page: 1, excerpt: "first", score: 3)
        let second = LibraryHit(path: "/tmp/b.pdf", folderID: "fixture", page: 1, excerpt: "second", score: 2)
        let third = LibraryHit(path: first.path, folderID: "fixture", page: 2, excerpt: "third", score: 1)
        let model = HomeModel()
        model.results = [first, second, third]
        XCTAssertEqual(model.resultIDs, [first.id, second.id, third.id])
        XCTAssertEqual(model.visibleHits.map(\.id), [first.id, third.id, second.id])
        model.selectResult(third)
        XCTAssertEqual(model.resultPosition, 1)
        model.resultOrder = .rank
        XCTAssertEqual(model.resultPosition, 2)
        model.moveResult(-1)
        XCTAssertEqual(model.selectedHit?.id, second.id)
        model.documentFilter = "a.pdf"
        model.filterDocuments()
        XCTAssertEqual(model.selectedHit?.id, first.id)
        XCTAssertEqual(model.rankedHits.map(\.rank), [1, 3])
        XCTAssertEqual(model.resultGroups.first?.rank(for: third), 3)

        var replacement = first
        replacement.matchQuery = "updated"
        model.results = [replacement, second, third]
        XCTAssertEqual(model.resultIDs, [first.id, second.id, third.id])
        XCTAssertEqual(model.visibleHits.first?.matchQuery, "updated")
        model.results = []
        XCTAssertTrue(model.resultIDs.isEmpty && model.visibleHits.isEmpty && model.resultGroups.isEmpty)
    }

    func testPreviewHashMatchesTheEditFingerprintAndHonoursCancellation() async throws {
        let bytes = Data(repeating: 0x2a, count: 2 * 1024 * 1024 + 17).dropFirst(11)
        XCTAssertEqual(try SourceDigest.cancellableSHA256(bytes), SHA256.hash(data: bytes))
        let work = Task { try SourceDigest.cancellableSHA256(bytes) }
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("Cancelled preview should stop hashing")
        } catch is CancellationError {}
    }

    func testSharedIndexRejectsAnotherRefreshWhileProgressYields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Sample".write(to: folder.appendingPathComponent("sample.md"), atomically: true, encoding: .utf8)
        let index = LibraryIndex(location: root.appendingPathComponent("index.sqlite"))
        try await index.add(folder)
        try await index.refresh { progress in
            guard progress.completed == 0, !progress.preparingSearch else { return }
            do {
                try await index.refresh { _ in }
                XCTFail("An active refresh must have exclusive access to the traversal")
            } catch LibraryIndex.Failure.refreshing {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        let summary = try await index.summary()
        XCTAssertEqual(summary.documents, 1)
    }

    func testUnchangedIndexKeepsResultsAndExternalUpdateInvalidatesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("sample.md")
        try "# Alpha\n\nOriginal content.".write(to: file, atomically: true, encoding: .utf8)
        let location = root.appendingPathComponent("index.sqlite")
        let index = LibraryIndex(location: location)
        try await index.add(folder)
        try await index.refresh { _ in }

        let model = HomeModel(index: index)
        await model.load()
        let hits = try await index.rankedSearch("alpha")
        let hit = try XCTUnwrap(hits.first)
        model.results = hits
        model.selectResult(hit)
        let revision = model.libraryRevision

        try await index.refresh { _ in }
        await model.load()
        XCTAssertEqual(model.libraryRevision, revision)
        XCTAssertEqual(model.selectedHit?.id, hit.id)

        try "# Omega\n\nUpdated content.".write(to: file, atomically: true, encoding: .utf8)
        let otherConnection = LibraryIndex(location: location)
        try await otherConnection.refresh { _ in }
        await model.load()
        XCTAssertNotEqual(model.libraryRevision, revision)
        XCTAssertNil(model.selectedHit)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testMovingBetweenPagesKeepsPDFAndClearingResultsReleasesIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let writer = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for _ in 0..<2 { writer.beginPDFPage(nil); writer.endPDFPage() }
        writer.closePDF()
        let model = SearchPDFModel()
        let revision = UUID()
        model.show(LibraryHit(path: url.path, folderID: "fixture", page: 1, excerpt: "", score: 0), revision: revision)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let document = try XCTUnwrap(model.document)
        model.show(LibraryHit(path: url.path, folderID: "fixture", page: 2, excerpt: "", score: 0), revision: revision)
        XCTAssertTrue(model.document === document)
        model.show(nil, revision: revision)
        XCTAssertNil(model.document)
        XCTAssertFalse(model.loading)

        model.show(LibraryHit(path: url.path, folderID: "fixture", page: 1, excerpt: "", score: 0), revision: revision)
        model.show(nil, revision: revision)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.document, "A cancelled load must not restore a closed preview")
        XCTAssertFalse(model.loading)
    }

    func testSelectingSameResultRevealsPageWithoutReloadingOrZooming() {
        _ = NSApplication.shared
        let document = PDFDocument()
        for _ in 0..<4 {
            let image = NSImage(size: NSSize(width: 600, height: 800))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 800).fill(); image.unlockFocus()
            document.insert(PDFPage(image: image)!, at: document.pageCount)
        }
        let model = HomeModel()
        let hit = LibraryHit(path: "/tmp/reveal-test.pdf", folderID: "reveal-test", page: 1, excerpt: "", score: 0)
        model.selectResult(hit)
        let initialID = model.resultRevealID
        var canvas = SearchPDFCanvas(document: document, page: 1, query: "", revealID: initialID)
        let coordinator = canvas.makeCoordinator()
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        view.displayMode = .singlePageContinuous; view.autoScales = false; view.scaleFactor = 0.75
        canvas.update(view, coordinator: coordinator)
        view.go(to: document.page(at: 3)!)
        XCTAssertTrue(view.currentPage === document.page(at: 3))
        canvas.update(view, coordinator: coordinator)
        XCTAssertTrue(view.currentPage === document.page(at: 3), "Unrelated updates must preserve scrolling")
        let scale = view.scaleFactor
        model.selectResult(hit)
        XCTAssertNotEqual(model.resultRevealID, initialID)
        canvas.revealID = model.resultRevealID
        canvas.update(view, coordinator: coordinator)
        XCTAssertTrue(view.currentPage === document.page(at: 0))
        XCTAssertTrue(view.document === document)
        XCTAssertEqual(view.scaleFactor, scale, accuracy: 0.001)
    }
}
