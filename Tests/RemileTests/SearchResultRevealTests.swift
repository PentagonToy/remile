import XCTest
import PDFKit
@testable import Remile

@MainActor final class SearchResultRevealTests: XCTestCase {
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
