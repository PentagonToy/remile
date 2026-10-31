import AppKit
import XCTest
@testable import Remile

final class ReviewHighlightTests: XCTestCase {
    @MainActor func testDeletionMarksOnlyItsMissingTextPositionAndInsertionKeepsItsExactRange() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController(); controller.texTheme = .remile
        let scroll = controller.makeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll; window.orderFront(nil)
        defer { window.orderOut(nil) }
        let source = "where $c(x,t)$ is the concentration.\nAdded sentence.\n"
        controller.update(source, size: 17, serif: false, document: "fixture")
        let view = try XCTUnwrap(controller.textView as? MarkdownSourceTextView)
        let layout = try XCTUnwrap(view.layoutManager)
        let added = (source as NSString).range(of: "Added sentence.")
        XCTAssertTrue(controller.reveal(range: added, select: false))
        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: added.location, effectiveRange: nil))
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 8, effectiveRange: nil))
        XCTAssertTrue(controller.reveal(range: NSRange(location: 6, length: 0), select: false, deletion: true))
        XCTAssertEqual(view.reviewDeletionOffset, 6)
        for index in 0..<(source as NSString).length {
            XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil), "Deletion must not colour the paragraph or maths")
        }
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
        scroll.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.visibleRect))
        view.cacheDisplay(in: view.visibleRect, to: bitmap)
        var redPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   colour.redComponent > colour.greenComponent + 0.2,
                   colour.redComponent > colour.blueComponent + 0.2 { redPixels += 1 }
            }
        }
        XCTAssertGreaterThan(redPixels, 2, "The deletion point must actually paint a red marker")
        view.sourceInteraction()
        XCTAssertNil(view.reviewDeletionOffset)
        XCTAssertTrue(controller.reveal(range: NSRange(location: (source as NSString).length, length: 0), select: false, deletion: true))
        XCTAssertEqual(view.reviewDeletionOffset, (source as NSString).length)
    }
}
