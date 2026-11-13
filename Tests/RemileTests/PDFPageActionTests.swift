import XCTest
import CoreText
import PDFKit
import SwiftUI
@testable import Remile

@MainActor final class PDFPageActionTests: XCTestCase {
    private func document() -> PDFDocument {
        let document = PDFDocument()
        for size in [NSSize(width: 634, height: 833), NSSize(width: 504, height: 720), NSSize(width: 504, height: 720)] {
            let image = NSImage(size: size)
            image.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill(); image.unlockFocus()
            document.insert(PDFPage(image: image)!, at: document.pageCount)
        }
        return document
    }
    func testFitIsOneShotAndUsesCurrentPage() {
        _ = NSApplication.shared
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.displayMode = .singlePageContinuous; view.document = document()
        let zoom = ReaderZoom(); zoom.attach(view)
        let coverScale = view.scaleFactor
        view.go(to: view.document!.page(at: 1)!)
        zoom.completePendingFit(in: view)
        XCTAssertEqual(view.scaleFactor, coverScale, accuracy: 0.001)
        view.setFrameSize(NSSize(width: 700, height: 500))
        zoom.completePendingFit(in: view)
        XCTAssertEqual(view.scaleFactor, coverScale, accuracy: 0.001)
        zoom.fit(.page)
        XCTAssertFalse(view.autoScales)
        XCTAssertNotEqual(view.scaleFactor, coverScale)
        let page = view.currentPage!
        let rectangle = view.convert(page.bounds(for: view.displayBox), from: page)
        XCTAssertLessThanOrEqual(rectangle.height, view.bounds.height + 1)
        XCTAssertGreaterThanOrEqual(rectangle.minY, -1)
        XCTAssertLessThanOrEqual(rectangle.maxY, view.bounds.maxY + 1)
        let clip = view.documentView!.enclosingScrollView!.contentView
        let visible = view.convert(clip.bounds, from: clip)
        XCTAssertEqual(rectangle.midY, visible.midY, accuracy: 2)
    }
    func testFitWidthIncludesBothPages() {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.displayMode = .twoUpContinuous; view.displaysAsBook = false; view.document = document()
        let zoom = ReaderZoom(); zoom.attach(view); zoom.fit(.width)
        let first = view.convert(view.document!.page(at: 0)!.bounds(for: view.displayBox), from: view.document!.page(at: 0)!)
        let second = view.convert(view.document!.page(at: 1)!.bounds(for: view.displayBox), from: view.document!.page(at: 1)!)
        XCTAssertLessThanOrEqual(first.union(second).width, view.bounds.width + 1)
        let fittedScale = view.scaleFactor
        zoom.change(1.8)
        zoom.fit(.width)
        XCTAssertEqual(view.scaleFactor, fittedScale, accuracy: 0.01)
    }
    func testFitHeightUsesAvailableHeightInANarrowViewport() {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        view.document = document()
        let zoom = ReaderZoom(); zoom.attach(view)
        let initial = view.scaleFactor
        zoom.fit(.height)
        XCTAssertGreaterThan(view.scaleFactor, initial)
        let page = view.currentPage!
        let rect = view.convert(page.bounds(for: view.displayBox), from: page)
        XCTAssertGreaterThan(rect.width, view.bounds.width)
        XCTAssertLessThanOrEqual(rect.height, view.bounds.height + 1)
    }
    func testFixedZoomSurvivesViewReplacement() {
        let doc = document()
        let first = PDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800)); first.document = doc
        let zoom = ReaderZoom(); zoom.attach(first)
        let scale = first.scaleFactor
        let next = PDFView(frame: NSRect(x: 0, y: 0, width: 650, height: 500)); next.document = doc
        zoom.attach(next)
        XCTAssertEqual(next.scaleFactor, scale, accuracy: 0.001)
        XCTAssertFalse(next.autoScales)
    }
    func testInitialFitWaitsForViewportThenStops() {
        let view = PDFView(frame: .zero); view.document = document()
        let zoom = ReaderZoom(); zoom.attach(view)
        view.setFrameSize(NSSize(width: 800, height: 600))
        zoom.completePendingFit(in: view)
        let scale = view.scaleFactor
        XCTAssertGreaterThan(scale, 0.1); XCTAssertLessThan(scale, 1)
        view.setFrameSize(NSSize(width: 1000, height: 800))
        zoom.completePendingFit(in: view)
        XCTAssertEqual(view.scaleFactor, scale, accuracy: 0.001)
    }
    func testInitialFitCompletesWhenTheDocumentArrivesAfterLayout() {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let zoom = ReaderZoom(); zoom.attach(view)
        view.document = document()
        zoom.completePendingFit(in: view)
        XCTAssertFalse(view.autoScales)
        XCTAssertLessThan(view.scaleFactor, 1)
        let scale = view.scaleFactor
        view.setFrameSize(NSSize(width: 950, height: 750))
        zoom.completePendingFit(in: view)
        XCTAssertEqual(view.scaleFactor, scale, accuracy: 0.001)
    }
    func testTeXPreviewReplacementKeepsPageAndReadingPosition() throws {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 510))
        view.displayMode = .singlePageContinuous
        let original = document()
        view.document = original
        let zoom = ReaderZoom(); zoom.attach(view); zoom.change(1.25)
        let second = try XCTUnwrap(original.page(at: 1))
        view.go(to: PDFDestination(page: second, at: CGPoint(x: 0, y: 370)))
        let position = try XCTUnwrap(view.currentDestination)

        let rebuilt = document()
        TeXPDFPreview(document: rebuilt, zoom: zoom, controller: TeXPDFController(), jump: nil).updateDocument(in: view)
        let restored = try XCTUnwrap(view.currentDestination)
        XCTAssertTrue(restored.page === rebuilt.page(at: 1))
        XCTAssertEqual(restored.point.y, position.point.y, accuracy: 2)
        XCTAssertEqual(view.scaleFactor, 1.25, accuracy: 0.001)
    }
    func testFitUsesRotatedPageGeometry() {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let doc = document(); doc.page(at: 0)!.rotation = 90; view.document = doc
        let zoom = ReaderZoom(); zoom.attach(view)
        let page = view.currentPage!, rect = view.convert(page.bounds(for: view.displayBox), from: page)
        XCTAssertLessThanOrEqual(rect.width, view.bounds.width + 1)
        XCTAssertLessThanOrEqual(rect.height, view.bounds.height + 1)
    }
    func testDeletePagesAndUndo() {
        let session = PDFSession(); session.load(document().dataRepresentation()!)
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        let document = session.document!, selected = document.page(at: 1)!
        session.selectOverviewPage(selected); session.selectedOverviewPages = [ObjectIdentifier(selected)]
        undo.beginUndoGrouping(); session.deleteOverviewPages(); undo.endUndoGrouping()
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(document.pageCount, 3)
        undo.redo()
        XCTAssertEqual(document.pageCount, 2)
    }
    func testThumbnailMenuTargetsRightClickedPage() async throws {
        let session = PDFSession(); session.load(document().dataRepresentation()!)
        let host = NSHostingView(rootView: PDFThumbnailOverview(session: session, keepsThumbnails: true))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600); host.layoutSubtreeIfNeeded()
        func collection(in view: NSView) -> PageCollectionView? {
            if let found = view as? PageCollectionView { return found }
            for child in view.subviews { if let found = collection(in: child) { return found } }
            return nil
        }
        let collection = try XCTUnwrap(collection(in: host))
        let coordinator = try XCTUnwrap(collection.actions)
        for _ in 0..<50 where coordinator.updating { try await Task.sleep(for: .milliseconds(10)) }
        let page = session.document!.page(at: 1)!
        let menu = try XCTUnwrap(coordinator.menu(at: 1))
        let item = try XCTUnwrap(menu.item(withTitle: "Delete Page"))
        XCTAssertTrue(item.isEnabled); XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(session.selectedOverviewPages, [ObjectIdentifier(page)])
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(session.document!.pageCount, 2)
    }

    func testNotesAndHighlightsPublishInPageBatches() async throws {
        let source = document()
        for index in 0..<source.pageCount {
            let page = try XCTUnwrap(source.page(at: index))
            for mark in 0..<12 {
                let bounds = CGRect(x: 40, y: 40 + mark * 24, width: 20, height: 16)
                page.addAnnotation(PDFNotes.make(text: "Note \(index)-\(mark)", author: "Fixture", bounds: bounds))
                let highlight = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                highlight.contents = "Highlight \(index)-\(mark)"
                page.addAnnotation(highlight)
            }
        }
        let session = PDFSession()
        session.load(try XCTUnwrap(source.dataRepresentation()))
        var noteCounts: [Int] = []
        var highlightCounts: [Int] = []
        let notes = session.$comments.sink { noteCounts.append($0.count) }
        let highlights = session.$highlights.sink { highlightCounts.append($0.count) }
        defer { notes.cancel(); highlights.cancel(); session.stop() }
        session.loadComments()
        for _ in 0..<100 where session.loadingComments { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.loadingComments)
        XCTAssertEqual(noteCounts.filter { $0 > 0 }, [12, 36])
        XCTAssertEqual(highlightCounts.filter { $0 > 0 }, [12, 36])
        let pageNumbers = [1, 2, 3].flatMap { Array(repeating: $0, count: 12) }
        XCTAssertEqual(session.comments.map(\.pageNumber), pageNumbers)
        XCTAssertEqual(session.highlights.map(\.pageNumber), pageNumbers)
        session.suspendCommentScan()
        XCTAssertEqual(session.comments.map(\.pageNumber), pageNumbers, "A finished scan remains available on reopen")

        let reopened = PDFSession()
        reopened.load(try XCTUnwrap(source.dataRepresentation()))
        reopened.loadComments()
        XCTAssertTrue(reopened.loadingComments)
        reopened.suspendCommentScan()
        await Task.yield()
        XCTAssertFalse(reopened.loadingComments)
        XCTAssertTrue(reopened.comments.isEmpty && reopened.highlights.isEmpty)
        reopened.loadComments()
        for _ in 0..<100 where reopened.loadingComments { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(reopened.loadingComments)
        XCTAssertEqual(reopened.comments.map(\.pageNumber), pageNumbers)
        XCTAssertEqual(reopened.highlights.map(\.pageNumber), pageNumbers)
    }

    func testSearchPublishesFirstMatchAndBatchesThroughLimit() async throws {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for page in 0..<30 {
            writer.beginPDFPage(nil)
            for line in 0..<20 {
                let word = page < 25 ? "needle Exact" : "needle"
                let text = NSAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: 14)])
                writer.textPosition = CGPoint(x: 42, y: 730 - line * 24)
                CTLineDraw(CTLineCreateWithAttributedString(text), writer)
            }
            writer.endPDFPage()
        }
        writer.closePDF()
        let session = PDFSession()
        session.load(data as Data)
        var updates: [Int] = []
        let observation = session.$matches.sink { updates.append($0.count) }
        defer { observation.cancel(); session.stop() }

        session.query = "  NEEDLE  "
        session.search()
        for _ in 0..<250 where session.searching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.searching)
        XCTAssertTrue(session.resultLimitReached)
        XCTAssertEqual(session.matches.count, 500)
        XCTAssertEqual(session.matches.map(\.page), (1...25).flatMap { Array(repeating: $0, count: 20) })
        XCTAssertEqual(updates.filter { $0 > 0 }.first, 1)
        XCTAssertEqual(updates.filter { $0 > 0 }.count, 33)
        let first = try XCTUnwrap(session.matches.first)
        let excerpt = session.excerpt(for: first)
        XCTAssertEqual(String(excerpt.characters).trimmingCharacters(in: .whitespacesAndNewlines), "needle Exact")
        let marked = excerpt.runs.filter { $0.swiftUI.backgroundColor != nil }
        XCTAssertEqual(marked.map { String(excerpt[$0.range].characters) }, ["needle"])
        let second = try XCTUnwrap(session.matches.dropFirst().first)
        XCTAssertEqual(excerpt, session.excerpt(for: second))
        let firstPage = try XCTUnwrap(first.selection.pages.first)
        XCTAssertNotEqual(first.selection.bounds(for: firstPage), second.selection.bounds(for: firstPage))

        session.caseSensitive = true
        session.query = "Exact"
        session.search()
        for _ in 0..<250 where session.searching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.searching)
        XCTAssertFalse(session.resultLimitReached)
        XCTAssertEqual(session.matches.count, 500)
        XCTAssertTrue(session.matches.allSatisfy { $0.selection.string == "Exact" })
        let updated = session.excerpt(for: try XCTUnwrap(session.matches.first))
        XCTAssertEqual(updated.runs.filter { $0.swiftUI.backgroundColor != nil }.map { String(updated[$0.range].characters) }, ["Exact"])
    }
    func testCannotDeleteEveryPage() {
        let session = PDFSession(); session.load(document().dataRepresentation()!)
        session.selectedOverviewPages = Set((0..<session.document!.pageCount).map { ObjectIdentifier(session.document!.page(at: $0)!) })
        session.deleteOverviewPages()
        XCTAssertEqual(session.document!.pageCount, 3)
        XCTAssertNotNil(session.editingError)
    }
}
