import PDFKit
import SwiftUI

struct PDFReader: NSViewRepresentable {
    @ObservedObject var session: PDFSession
    @AppStorage(ReaderScrolling.preference) private var elasticScrolling = true
    var zoom: ReaderZoom? = nil
    var selectionActions = PDFSelectionActions()
    var openPDFs: (([URL]) -> Bool)? = nil
    var canvasReuse: PDFCanvasReuse<PDFSelectionView>? = nil

    @MainActor final class Coordinator {
        let citations = PDFCitationHighlights()
        weak var session: PDFSession?
        weak var zoom: ReaderZoom?
        weak var canvasReuse: PDFCanvasReuse<PDFSelectionView>?
        var elasticScrolling: Bool?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = canvasReuse?.take { PDFSelectionView() } ?? PDFSelectionView()
        view.selectionActions = selectionActions; view.openPDFs = openPDFs; view.receivesWindowPageKeys = true
        configureDrawing(view)
        view.pageOverlayViewProvider = context.coordinator.citations
        context.coordinator.citations.update(session.activeCitation)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.document = session.document
        ReaderScrolling.configure(view)
        session.attach(view)
        zoom?.attach(view)
        context.coordinator.session = session
        context.coordinator.zoom = zoom
        context.coordinator.canvasReuse = canvasReuse
        context.coordinator.elasticScrolling = elasticScrolling
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        (view as? PDFSelectionView)?.selectionActions = selectionActions
        (view as? PDFSelectionView)?.openPDFs = openPDFs
        if let selectionView = view as? PDFSelectionView { configureDrawing(selectionView) }
        let mode: PDFDisplayMode = session.twoPage ? .twoUpContinuous : .singlePageContinuous
        let displayChanged = view.displayMode != mode || view.displaysAsBook
        let scrollingChanged = context.coordinator.elasticScrolling != elasticScrolling
        context.coordinator.elasticScrolling = elasticScrolling
        if view.displayMode != mode { view.displayMode = mode }
        if view.displaysAsBook { view.displaysAsBook = false }
        context.coordinator.citations.update(session.activeCitation)
        if session.activeCitation != nil { view.highlightedSelections = [] }
        guard view.document !== session.document else {
            if displayChanged || scrollingChanged { ReaderScrolling.configure(view) }
            zoom?.completePendingFit(in: view)
            return
        }
        view.document = session.document
        ReaderScrolling.configure(view)
        zoom?.completePendingFit(in: view)
        session.applyLibraryDestination()
        session.restoreReadingPosition()
        context.coordinator.citations.update(session.activeCitation)
    }
    private func configureDrawing(_ view: PDFSelectionView) {
        if view.document !== session.document { view.cancelDrawing() }
        view.drawingTool = session.isEditing ? session.drawingTool : nil
        view.drawingColor = session.drawingColor.color
        view.editNote = { [weak session] note in session?.beginEditingNote(note) }
        view.beginDrawing = { [weak session] in session?.allowDrawingGesture() ?? false }
        view.commitDrawing = { [weak session] page, annotation in session?.addDrawing(annotation, on: page) }
        view.finishDrawing = { [weak session] in session?.drawingTool = nil }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        if let view = view as? PDFSelectionView {
            view.cancelDrawing(); view.drawingTool = nil; view.beginDrawing = nil; view.commitDrawing = nil; view.finishDrawing = nil
            view.selectionActions = PDFSelectionActions(); view.editNote = nil; view.openPDFs = nil
        }
        coordinator.session?.detach(view)
        coordinator.zoom?.detach(view)
        ReaderScrolling.detach(view)
        view.document?.cancelFindString()
        view.clearSelection()
        view.highlightedSelections = []
        view.pageOverlayViewProvider = nil; coordinator.citations.update(nil)
        view.document = nil
        coordinator.canvasReuse?.store(view)
    }
}
