import XCTest
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
        zoom.updateFitForLayout(pageChanged: true, selecting: false)
        XCTAssertEqual(view.scaleFactor, coverScale, accuracy: 0.001)
        view.setFrameSize(NSSize(width: 700, height: 500))
        zoom.updateFitForLayout(pageChanged: false, selecting: false)
        XCTAssertEqual(view.scaleFactor, coverScale, accuracy: 0.001)
        zoom.fit(width: false)
        XCTAssertFalse(view.autoScales)
        XCTAssertNotEqual(view.scaleFactor, coverScale)
        let page = view.currentPage!
        let rectangle = view.convert(page.bounds(for: view.displayBox), from: page)
        XCTAssertLessThanOrEqual(rectangle.height, view.bounds.height + 1)
        XCTAssertGreaterThanOrEqual(rectangle.minY, -1)
        XCTAssertLessThanOrEqual(rectangle.maxY, view.bounds.maxY + 1)
    }
    func testFitWidthIncludesBothPages() {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.displayMode = .twoUpContinuous; view.displaysAsBook = false; view.document = document()
        let zoom = ReaderZoom(); zoom.attach(view); zoom.fit(width: true)
        let first = view.convert(view.document!.page(at: 0)!.bounds(for: view.displayBox), from: view.document!.page(at: 0)!)
        let second = view.convert(view.document!.page(at: 1)!.bounds(for: view.displayBox), from: view.document!.page(at: 1)!)
        XCTAssertLessThanOrEqual(first.union(second).width, view.bounds.width + 1)
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
        zoom.updateFitForLayout(pageChanged: false, selecting: false)
        let scale = view.scaleFactor
        XCTAssertGreaterThan(scale, 0.1); XCTAssertLessThan(scale, 1)
        view.setFrameSize(NSSize(width: 1000, height: 800))
        zoom.updateFitForLayout(pageChanged: false, selecting: false)
        XCTAssertEqual(view.scaleFactor, scale, accuracy: 0.001)
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
        let host = NSHostingView(rootView: PDFThumbnailOverview(session: session))
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
    func testCannotDeleteEveryPage() {
        let session = PDFSession(); session.load(document().dataRepresentation()!)
        session.selectedOverviewPages = Set((0..<session.document!.pageCount).map { ObjectIdentifier(session.document!.page(at: $0)!) })
        session.deleteOverviewPages()
        XCTAssertEqual(session.document!.pageCount, 3)
        XCTAssertNotNil(session.editingError)
    }
}
