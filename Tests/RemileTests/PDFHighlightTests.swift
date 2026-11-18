import XCTest
import CoreText
import PDFKit
@testable import Remile

@MainActor final class PDFHighlightTests: XCTestCase {
    private func document() throws -> PDFDocument {
        _ = NSApplication.shared
        let bytes = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        writer.beginPDFPage(nil)
        let text = NSAttributedString(string: "Remile highlight fixture", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        writer.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(text), writer)
        writer.endPDFPage(); writer.closePDF()
        return try XCTUnwrap(PDFDocument(data: bytes as Data))
    }

    func testPaletteSetsTheDefaultAndHighlightAppliesItToCapturedText() throws {
        let savedColour = UserDefaults.standard.object(forKey: HighlightColor.preference)
        defer { UserDefaults.standard.set(savedColour, forKey: HighlightColor.preference) }
        HighlightColor.preferred = .yellow
        let doc = try document(), page = try XCTUnwrap(doc.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))
        let view = PDFSelectionView(); view.document = doc
        var applied: [HighlightColor] = []
        view.selectionActions.highlight = { context, colour in
            XCTAssertEqual(context.text, "Remile")
            applied.append(colour)
        }
        let menu = view.selectionMenu(for: selection)
        let highlight = try XCTUnwrap(menu.items.first { $0.title == "Highlight" })
        XCTAssertTrue(highlight.isEnabled)
        XCTAssertNotNil(highlight.image)
        let palette = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.presentationStyle == .palette })
        XCTAssertEqual(palette.items.map(\.title), HighlightColor.markupColors.map(\.name))
        XCTAssertEqual(palette.numberOfItems, 5)
        XCTAssertEqual(palette.items.prefix(4).map(\.title), ["Yellow", "Orange", "Blue", "Green"])
        view.setCurrentSelection(page.selection(for: NSRange(location: 7, length: 9)), animate: false)
        for (colour, item) in zip(HighlightColor.markupColors, palette.items) {
            XCTAssertNotNil(item.image)
            XCTAssertEqual(item.toolTip, item.title)
            XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertTrue(applied.isEmpty)
            XCTAssertEqual(HighlightColor.preferred, colour)
        }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(highlight.action), to: highlight.target, from: highlight))
        XCTAssertEqual(applied, [.reddishPurple])
        let reopened = view.selectionMenu(for: nil)
        XCTAssertFalse(try XCTUnwrap(reopened.items.first { $0.title == "Highlight" }).isEnabled)
        let savedPalette = try XCTUnwrap(reopened.items.compactMap(\.submenu).first)
        XCTAssertEqual(savedPalette.items.filter { $0.state == .on }.map(\.title), ["Purple"])
        let yellow = savedPalette.items[0]
        XCTAssertTrue(yellow.isEnabled)
        _ = NSApp.sendAction(try XCTUnwrap(yellow.action), to: yellow.target, from: yellow)
        XCTAssertEqual(HighlightColor.preferred, .yellow)
        XCTAssertEqual(applied.count, 1)
        view.selectionActions.canAnnotate = { _ in false }
        _ = NSApp.sendAction(try XCTUnwrap(highlight.action), to: highlight.target, from: highlight)
        XCTAssertEqual(applied.count, 1)
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testReaderHighlightUsesTheSavedDefault() throws {
        let savedColour = UserDefaults.standard.object(forKey: HighlightColor.preference)
        defer { UserDefaults.standard.set(savedColour, forKey: HighlightColor.preference) }
        HighlightColor.preferred = .blue
        let session = PDFSession()
        session.load(try XCTUnwrap(try document().dataRepresentation()))
        let view = PDFSelectionView(); view.document = session.document
        session.attach(view)
        let page = try XCTUnwrap(session.document?.page(at: 0))
        view.setCurrentSelection(page.selection(for: NSRange(location: 0, length: 6)), animate: false)
        session.highlightSelection()
        XCTAssertNil(session.editingError)
        XCTAssertEqual(page.annotations.first?.color, HighlightColor.blue.markupColor)
        session.stop()
    }

    func testDefaultColourIsIncludedInPreferences() throws {
        let suite = "remile.test.highlight." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HighlightColor.orange.rawValue, forKey: HighlightColor.preference)
        let snapshot = PortableSettings.snapshot(defaults)
        defaults.removeObject(forKey: HighlightColor.preference)
        try PortableSettings.apply(snapshot, to: defaults)
        XCTAssertEqual(defaults.string(forKey: HighlightColor.preference), HighlightColor.orange.rawValue)
        XCTAssertThrowsError(try PortableSettings.apply(.init(preferences: [HighlightColor.preference: .string("unknown")]), to: defaults))
        XCTAssertEqual(defaults.string(forKey: HighlightColor.preference), HighlightColor.orange.rawValue)
    }

    func testEveryHighlightTintSurvivesSaveAndReload() throws {
        for colour in HighlightColor.allCases {
            let doc = try document(), page = try XCTUnwrap(doc.page(at: 0))
            let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))
            let marks = try PDFEditing.highlights(for: selection, in: doc, color: colour)
            let note = try XCTUnwrap(marks.first?.1)
            XCTAssertEqual(note.color.alphaComponent, 1)
            let data = try PDFEditing.apply(marks, adding: true, in: doc, graph: PDFCommentGraph(document: doc))
            let reopened = try XCTUnwrap(PDFDocument(data: data))
            let savedPage = try XCTUnwrap(reopened.page(at: 0))
            let saved = try XCTUnwrap(savedPage.annotations.first { $0.type == "Highlight" })
            let expected = try XCTUnwrap(colour.markupColor.usingColorSpace(.sRGB))
            let actual = try XCTUnwrap(saved.color.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.005, colour.name)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.005, colour.name)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.005, colour.name)
            XCTAssertEqual(actual.alphaComponent, 1)
            let before = try pixel(in: note)
            let after = try pixel(in: saved)
            XCTAssertGreaterThan(min(before.redComponent, before.greenComponent, before.blueComponent), 0.3, colour.name)
            XCTAssertEqual(before.redComponent, after.redComponent, accuracy: 0.02, colour.name)
            XCTAssertEqual(before.greenComponent, after.greenComponent, accuracy: 0.02, colour.name)
            XCTAssertEqual(before.blueComponent, after.blueComponent, accuracy: 0.02, colour.name)
            XCTAssertEqual(savedPage.string, page.string)
        }
    }

    private func pixel(in annotation: PDFAnnotation) throws -> NSColor {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let bounds = annotation.bounds
        context.scaleBy(x: 64 / bounds.width, y: 32 / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        annotation.draw(with: .mediaBox, in: context)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        return try XCTUnwrap(bitmap.colorAt(x: 32, y: 16)?.usingColorSpace(.sRGB))
    }
}
