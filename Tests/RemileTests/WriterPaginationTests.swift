import XCTest
import AppKit
@testable import Remile

@MainActor final class WriterPaginationTests: XCTestCase {
    func testWriterStartsWithWholePageCentredInTheViewport() async throws {
        for size in [CGSize(width: 1500, height: 1180), CGSize(width: 500, height: 850)] {
            let (model, desk, window) = makeDesk(size: size)
            defer { desk.suspend(); window.contentView = nil }
            let page = try XCTUnwrap(model.canvas?.sheets.first)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(10))
                let frame = desk.convert(page.bounds, from: page)
                let viewport = desk.convert(desk.scroll.contentView.bounds, from: desk.scroll.contentView)
                if abs(model.zoom - 1) > 0.001 && abs(frame.midY - viewport.midY) <= 1 { break }
            }
            let frame = desk.convert(page.bounds, from: page)
            let viewport = desk.convert(desk.scroll.contentView.bounds, from: desk.scroll.contentView)
            let geometry = "Viewport \(viewport), page \(frame), zoom \(model.zoom)"
            XCTAssertEqual(frame.midX, viewport.midX, accuracy: 1, geometry)
            XCTAssertEqual(frame.midY, viewport.midY, accuracy: 1, geometry)
            XCTAssertLessThanOrEqual(frame.width, viewport.width)
            XCTAssertLessThanOrEqual(frame.height, viewport.height)
            if size.width > 1000 { XCTAssertGreaterThan(model.zoom, 1) }
            else { XCTAssertLessThan(model.zoom, 1) }

            model.resizePaper(PaperSize.a4.rawValue, landscape: true)
            desk.update()
            let insets = WriterCanvas.pageInsets
            let paper = model.pageSize
            let clipSize = desk.scroll.contentView.frame.size
            let target = min(2, clipSize.width / (paper.width + 2 * insets.width),
                             clipSize.height / (paper.height + 2 * insets.height))
            for _ in 0..<20 where abs(desk.scroll.magnification - target) > 0.002 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(desk.scroll.magnification, target, accuracy: 0.002)
        }
    }

    func testFitHeightCentresTheCurrentPageAndRetainsExplicitZoom() throws {
        let (model, desk, window) = makeDesk(size: CGSize(width: 1500, height: 1180))
        defer { desk.suspend(); window.contentView = nil }
        model.setZoom(1)
        var object = WriterObject(kind: .rectangle)
        object.page = 2
        model.insertObject(object)
        let canvas = try XCTUnwrap(model.canvas)
        canvas.paginate()
        desk.update()
        let secondPage = canvas.sheets[1]
        desk.scroll.contentView.scroll(to: CGPoint(x: 0, y: secondPage.frame.minY - 50))
        desk.scroll.reflectScrolledClipView(desk.scroll.contentView)
        model.fitPage(.height)

        let frame = desk.convert(secondPage.bounds, from: secondPage)
        let viewport = desk.convert(desk.scroll.contentView.bounds, from: desk.scroll.contentView)
        XCTAssertEqual(frame.midY, viewport.midY, accuracy: 1)
        XCTAssertEqual(frame.height + 2 * WriterCanvas.pageInsets.height * model.zoom, viewport.height, accuracy: 1)

        model.setZoom(0.75)
        desk.update()
        desk.layoutSubtreeIfNeeded()
        XCTAssertEqual(desk.scroll.magnification, 0.75, accuracy: 0.001)
    }

    private func makeDesk(size: CGSize) -> (WriterModel, WriterDesk, NSWindow) {
        _ = NSApplication.shared
        let model = WriterModel()
        let desk = WriterDesk(model: model)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = desk
        desk.frame.size = size
        desk.layoutSubtreeIfNeeded()
        return (model, desk, window)
    }

    func testWrappingAppliesToNewPagesAndClearsWhenRemoved() {
        _ = NSApplication.shared
        let model = WriterModel()
        var style = WriterPageStyle()
        style.columns = 2
        model.setPageStyle(style)
        let canvas = WriterCanvas(model: model)
        defer { canvas.suspend() }
        canvas.rebuild()
        XCTAssertEqual(canvas.sheets.count, 1)

        var shape = WriterObject(kind: .rectangle)
        shape.page = 2
        shape.wrapsText = true
        model.insertObject(shape)
        canvas.paginate()
        XCTAssertEqual(canvas.sheets.count, 3)
        XCTAssertTrue(canvas.sheets[0].texts.allSatisfy { $0.textContainer?.exclusionPaths.isEmpty == true })
        XCTAssertTrue(canvas.sheets[2].texts.contains { $0.textContainer?.exclusionPaths.isEmpty == false })

        shape.wrapsText = false
        model.update(shape)
        canvas.synchronise()
        XCTAssertTrue(canvas.sheets[2].texts.allSatisfy { $0.textContainer?.exclusionPaths.isEmpty == true })
        model.deleteShape()
        canvas.paginate()
        XCTAssertEqual(canvas.sheets.count, 1)
    }
}
