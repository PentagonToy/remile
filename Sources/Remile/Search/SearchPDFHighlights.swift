import PDFKit

/// Non-interactive page overlays make highlights independent of PDFKit selection focus.
@MainActor
final class SearchPDFHighlights: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    private var query = ""
    private var citation: AssistantCitation?
    private var overlays: [ObjectIdentifier: WeakOverlay] = [:]
    private var revealPage: PDFPage?
    private var revealSelections: [PDFSelection]?
    private struct WeakOverlay { weak var value: HighlightOverlay? }
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = HighlightOverlay(pdfView: view, page: page)
        overlay.update(selections(on: page))
        overlays[ObjectIdentifier(page)] = WeakOverlay(value: overlay)
        return overlay
    }
    func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
        guard let overlay = overlayView as? HighlightOverlay else { return }
        let key = ObjectIdentifier(page)
        guard overlays[key]?.value !== overlay else { return }
        overlay.update(selections(on: page))
        overlays[key] = WeakOverlay(value: overlay)
    }
    func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        let key = ObjectIdentifier(page)
        if overlays[key]?.value === overlayView { overlays.removeValue(forKey: key) }
    }

    // Share native selections with PDFKit's synchronous overlay callbacks during a reveal.
    func duringReveal(on page: PDFPage?, _ update: () -> Void) {
        revealPage = page
        defer { revealPage = nil; revealSelections = nil }
        update()
    }

    func selections(on page: PDFPage) -> [PDFSelection] {
        if let citation, page.document?.index(for: page) != citation.location.unit - 1 { return [] }
        if page === revealPage, let revealSelections { return revealSelections }
        let selections = citation.map { PDFCitation.selections(on: page, excerpt: $0.text) }
            ?? SearchPDFCanvas.selections(on: page, query: query)
        if page === revealPage { revealSelections = selections }
        return selections
    }

    func update(query: String, citation: AssistantCitation? = nil) {
        guard self.query != query || self.citation?.id != citation?.id else { return }
        self.query = query; self.citation = citation
        revealSelections = nil
        overlays = overlays.filter { $0.value.value != nil }
        for item in overlays.values {
            guard let overlay = item.value, let page = overlay.page else { continue }
            overlay.update(selections(on: page))
        }
    }
}

@MainActor
final class HighlightOverlay: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    private(set) var rectangles: [NSRect] = []
    init(pdfView: PDFView, page: PDFPage) {
        self.pdfView = pdfView; self.page = page
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(_ selections: [PDFSelection]) {
        rectangles = selections.flatMap { selection in
            selection.selectionsByLine().compactMap { line in line.pages.first.map { line.bounds(for: $0) } }
        }
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
