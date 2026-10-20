import PDFKit

/// Non-interactive page overlays make highlights independent of PDFKit selection focus.
@MainActor
final class SearchPDFHighlights: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    var query = ""
    private var citation: AssistantCitation?
    private var overlays: [ObjectIdentifier: WeakOverlay] = [:]
    private struct WeakOverlay { weak var value: HighlightOverlay? }
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = HighlightOverlay(pdfView: view, page: page, query: query, citation: citation)
        overlays[ObjectIdentifier(page)] = WeakOverlay(value: overlay)
        return overlay
    }
    func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) { overlayView.needsDisplay = true }
    func update(query: String, citation: AssistantCitation? = nil) {
        guard self.query != query || self.citation?.id != citation?.id else { return }
        self.query = query; self.citation = citation
        overlays = overlays.filter { $0.value.value != nil }
        for item in overlays.values { item.value?.update(query: query, citation: citation) }
    }
}

@MainActor
final class HighlightOverlay: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    private var rectangles: [NSRect] = []
    init(pdfView: PDFView, page: PDFPage, query: String, citation: AssistantCitation? = nil) {
        self.pdfView = pdfView; self.page = page
        super.init(frame: .zero); update(query: query, citation: citation)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(query: String, citation: AssistantCitation? = nil) {
        rectangles = page.map { page in
            let selected = citation.map { source in
                page.document?.index(for: page) == source.location.unit - 1 ? PDFCitation.selections(on: page, excerpt: source.text) : []
            } ?? SearchPDFCanvas.selections(on: page, query: query)
            return selected.flatMap { selection in selection.selectionsByLine().compactMap { line in line.pages.first.map { line.bounds(for: $0) } } }
        } ?? []
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let page else { return }
        HighlightColor.yellow.color.withAlphaComponent(0.38).setFill()
        for rectangle in rectangles {
            let bounds = convert(pdfView.convert(rectangle, from: page), from: pdfView)
            NSBezierPath(roundedRect: bounds.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
        }
    }
}
