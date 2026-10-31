import AppKit
import SwiftUI
import XCTest
@testable import Remile

final class EditorLineNumberTests: XCTestCase {
    @MainActor func testExternalTeXInsertionKeepsTheCaretOnItsText() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        controller.texTheme = .remile
        _ = controller.makeView()
        let source = String(repeating: "% Opening lines\n", count: 12) + "Unique paragraph with a caret here and some stable nearby text.\n"
        controller.update(source, size: 17, serif: false, document: "main.tex")
        let view = try XCTUnwrap(controller.textView)
        let selection = (source as NSString).range(of: "caret")
        view.setSelectedRange(selection)
        let added = "% Remote section added above\n"
        controller.update(added + source, size: 17, serif: false, document: "main.tex")
        XCTAssertEqual(view.selectedRange(), NSRange(location: selection.location + (added as NSString).length, length: selection.length))
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "caret")
    }
    func testAmbiguousCaretContextAndUnicodeFallbackStayConservative() {
        let repeated = String(repeating: "x", count: 400)
        XCTAssertEqual(EditorProvenance.anchoredSelection(NSRange(location: 150, length: 0), before: repeated, after: "prefix" + repeated), NSRange(location: 150, length: 0))
        let mapped = EditorProvenance.anchoredSelection(NSRange(location: 1, length: 0), before: "a", after: "😀")
        XCTAssertNotNil(Range(mapped, in: "😀"))
        XCTAssertEqual(mapped.length, 0)
    }
    @MainActor func testGutterPaintStaysInsideItsOwnBounds() async throws {
        _ = NSApplication.shared
        let store = UserDefaults.standard, key = "latex.lineNumbers", original = UserDefaults.standard.object(forKey: "latex.lineNumbers")
        defer { if let original { store.set(original, forKey: key) } else { store.removeObject(forKey: key) } }
        store.set(true, forKey: key)
        let controller = MarkdownEditorController(); controller.texTheme = .remile
        let scroll = controller.makeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 280), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = scroll
        controller.update("\\section{Visible source}\nText must remain visible.\n", size: 17, serif: false, document: "capture")
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        scroll.layoutSubtreeIfNeeded()
        let ruler = try XCTUnwrap(scroll.verticalRulerView)
        XCTAssertLessThanOrEqual(ruler.bounds.width, 60)
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let x = Int(200 * CGFloat(bitmap.pixelsWide) / scroll.bounds.width)
        let y = Int(200 * CGFloat(bitmap.pixelsHigh) / scroll.bounds.height)
        let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        let gutterX = Int(20 * CGFloat(bitmap.pixelsWide) / scroll.bounds.width)
        let gutter = try XCTUnwrap(bitmap.colorAt(x: gutterX, y: y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(abs(pixel.greenComponent - gutter.greenComponent), 0.01, "Gutter paint must not cover the source background")
        if let directory = ProcessInfo.processInfo.environment["REMILE_SOURCE_TAB_CAPTURE"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("source-gutter-dark.png"))
        }
    }
    @MainActor func testTogglingNumbersPreservesSourceSelectionAndEditor() throws {
        _ = NSApplication.shared
        let store = UserDefaults.standard
        for tex in [false, true] {
            let key = tex ? "latex.lineNumbers" : "markdown.lineNumbers"
            let original = store.object(forKey: key)
            defer { if let original { store.set(original, forKey: key) } else { store.removeObject(forKey: key) } }
            store.removeObject(forKey: key)
            let controller = MarkdownEditorController()
            controller.texTheme = tex ? .remile : nil
            let scroll = controller.makeView()
            scroll.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
            let source = "First line\nSecond line\nThird line\n"
            controller.update(source, size: 17, serif: false, document: "fixture")
            let editor = try XCTUnwrap(controller.textView)
            editor.setSelectedRange(NSRange(location: 1, length: 3))
            XCTAssertTrue(scroll.rulersVisible, "Line numbers default to on")
            XCTAssertTrue(scroll.verticalRulerView is EditorLineRuler)
            for enabled in [false, true] {
                store.set(enabled, forKey: key)
                controller.update(source, size: 17, serif: false, document: "fixture")
                XCTAssertEqual(scroll.rulersVisible, enabled)
                XCTAssertTrue(controller.textView === editor)
                XCTAssertEqual(editor.string, source)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 3))
            }
        }
    }
}
