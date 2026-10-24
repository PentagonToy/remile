import AppKit
import PDFKit

/// Native image representations let Notes and other editors accept a drag without temporary files.
@MainActor
final class PDFImageDrag: NSObject, NSDraggingSource {
    struct Candidate {
        let page: PDFPage
        let reference: CGPDFPage?
        let bounds: CGRect
        let crop: CGRect
        let rotation: Int
        let start: CGPoint
        @MainActor func isCurrent(in view: PDFView) -> Bool {
            page.document === view.document && page.document?.allowsCopying == true &&
            page.pageRef === reference && page.bounds(for: .cropBox) == crop && page.rotation == rotation
        }
    }
    private weak var view: PDFView?
    private var candidate: Candidate?
    private var consumed = false
    var isPending: Bool { consumed }
    init(view: PDFView) { self.view = view }
    func cancel() { candidate = nil; consumed = false }
    func prepare(at location: CGPoint) -> Bool {
        cancel()
        guard let view, let page = view.page(for: location, nearest: false) else { return false }
        let point = view.convert(location, to: page)
        // Keep ordinary text selection available on scanned pages with an OCR layer.
        guard !Self.hasText(at: point, on: page), let bounds = PDFContentRegions.imageBounds(at: point, on: page) else { return false }
        candidate = Candidate(page: page, reference: page.pageRef, bounds: bounds, crop: page.bounds(for: .cropBox), rotation: page.rotation, start: location)
        consumed = true
        return true
    }
    static func hasText(at point: CGPoint, on page: PDFPage) -> Bool {
        let index = page.characterIndex(at: point)
        guard index != NSNotFound, index >= 0, index < page.numberOfCharacters else { return false }
        return page.characterBounds(at: index).contains(point)
    }
    static func image(_ candidate: Candidate, in view: PDFView) throws -> NSImage {
        guard candidate.isCurrent(in: view) else { throw PDFContentRegions.Failure("The page changed. Choose the image again.") }
        let bytes = try PDFContentRegions.png(PDFContentRegions.Snapshot(candidate.page), bounds: candidate.bounds)
        guard let image = NSImage(data: bytes) else { throw PDFContentRegions.Failure("This image could not be prepared.") }
        return image
    }
    @discardableResult func drag(with event: NSEvent) -> Bool {
        guard let candidate, let view else { return consumed }
        let location = view.convert(event.locationInWindow, from: nil)
        guard hypot(location.x - candidate.start.x, location.y - candidate.start.y) >= 6 else { return true }
        defer { self.candidate = nil }
        do {
            let image = try Self.image(candidate, in: view)
            let item = NSDraggingItem(pasteboardWriter: image)
            let rect = view.convert(candidate.bounds, from: candidate.page)
            let scale = min(1, 240 / max(rect.width, rect.height))
            let size = CGSize(width: rect.width * scale, height: rect.height * scale)
            let offset = CGPoint(x: (candidate.start.x - rect.minX) * scale, y: (candidate.start.y - rect.minY) * scale)
            item.setDraggingFrame(CGRect(x: location.x - offset.x, y: location.y - offset.y, width: size.width, height: size.height), contents: image)
            view.beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
        } catch {
            if let window = view.window {
                let alert = NSAlert(); alert.messageText = "Image could not be dragged"; alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
        return true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
