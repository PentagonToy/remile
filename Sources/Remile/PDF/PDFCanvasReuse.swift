import PDFKit

/// One empty canvas per reader or preview owner. PDFKit can keep retired canvases
/// alive during page analysis, so reuse a fully detached view when possible.
@MainActor final class PDFCanvasReuse<Canvas: PDFView> {
    private var available: Canvas?

    func take(_ create: () -> Canvas) -> Canvas {
        guard let canvas = available, canvas.superview == nil, canvas.window == nil else { return create() }
        available = nil
        return canvas
    }

    func store(_ view: PDFView) {
        guard view.document == nil, let canvas = view as? Canvas else { return }
        available = canvas
    }
}
