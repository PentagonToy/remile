import XCTest
import CoreText
import PDFKit
@testable import Remile

@MainActor final class PDFSelectionTextTests: XCTestCase {
    func testHighlightReadsPageRangesWithoutCallingTheLineStringGetter() throws {
        _ = NSApplication.shared
        let bytes = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        writer.beginPDFPage(nil)
        let text = NSAttributedString(string: "Remile editing fixture", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        writer.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(text), writer)
        writer.endPDFPage(); writer.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: bytes as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        let readable = UnreadableLineSelection(page: page, ranges: [NSRange(location: 0, length: 6)])
        XCTAssertEqual(PDFSelectionText.string(for: readable, on: page), "Remile")
        let marks = try PDFEditing.highlights(for: readable, in: document)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.1.contents, "Remile")
        let separated = UnreadableLineSelection(page: page, ranges: [NSRange(location: 0, length: 6), NSRange(location: 7, length: 7)])
        XCTAssertEqual(PDFSelectionText.string(for: separated, on: page), "Remileediting")

        let length = (try XCTUnwrap(page.string) as NSString).length
        for range in [
            NSRange(location: NSNotFound, length: 1),
            NSRange(location: -1, length: 1),
            NSRange(location: 0, length: -1),
            NSRange(location: 0, length: 0),
            NSRange(location: 1, length: Int.max),
            NSRange(location: length, length: 1)
        ] {
            let invalid = UnreadableLineSelection(page: page, ranges: [range])
            XCTAssertNil(PDFSelectionText.string(for: invalid, on: page))
            XCTAssertThrowsError(try PDFEditing.highlights(for: invalid, in: document))
        }
        XCTAssertTrue(page.annotations.isEmpty)
    }
}

private final class UnreadableLineSelection: PDFSelection {
    let sourcePage: PDFPage
    let textRanges: [NSRange]
    init(page: PDFPage, ranges: [NSRange]) {
        sourcePage = page; textRanges = ranges
        super.init(document: page.document!)
    }
    override var pages: [PDFPage] { [sourcePage] }
    override var string: String? { preconditionFailure("Do not call PDFKit's unsafe line string getter") }
    override func numberOfTextRanges(on page: PDFPage) -> Int { textRanges.count }
    override func range(at index: Int, on page: PDFPage) -> NSRange { textRanges[index] }
    override func selectionsByLine() -> [PDFSelection] { [self] }
    override func bounds(for page: PDFPage) -> NSRect { NSRect(x: 72, y: 700, width: 120, height: 18) }
}
