import PDFKit

/// Citation marks are view state, never annotations written into the source PDF.
enum PDFCitation {
    static func selections(on page: PDFPage, excerpt: String) -> [PDFSelection] {
        guard let text = page.string else { return [] }
        let citation = AssistantCitation(location: AssistantLocation(path: "", unit: 0, label: ""), text: excerpt)
        return citation.ranges(in: text).compactMap { range in
            guard let selection = page.selection(for: range) else { return nil }
            selection.color = HighlightColor.yellow.color.withAlphaComponent(0.4)
            return selection
        }
    }
}

@MainActor
final class PDFCitationHighlights: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    private var citation: AssistantCitation?
    private struct WeakOverlay { weak var view: PDFCitationOverlay? }
    private var overlays: [ObjectIdentifier: WeakOverlay] = [:]
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PDFCitationOverlay(pdfView: view, page: page)
        overlay.update(citation); overlays[ObjectIdentifier(page)] = WeakOverlay(view: overlay)
        return overlay
    }
    func update(_ citation: AssistantCitation?) {
        guard self.citation?.id != citation?.id else { return }
        self.citation = citation; overlays = overlays.filter { $0.value.view != nil }
        for item in overlays.values { item.view?.update(citation) }
    }
}

@MainActor
final class PDFCitationOverlay: NSView {
    private weak var pdfView: PDFView?
    private weak var page: PDFPage?
    private var rectangles: [NSRect] = []
    init(pdfView: PDFView, page: PDFPage) {
        self.pdfView = pdfView; self.page = page; super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(_ citation: AssistantCitation?) {
        rectangles = []
        if let citation, let page, let document = page.document, citation.location.unit > 0,
           document.index(for: page) == citation.location.unit - 1 {
            rectangles = PDFCitation.selections(on: page, excerpt: citation.text).flatMap { selection in
                selection.selectionsByLine().map { $0.bounds(for: page) }
            }
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
