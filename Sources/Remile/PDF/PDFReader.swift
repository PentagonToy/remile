import PDFKit
import SwiftUI

struct PDFReader: NSViewRepresentable {
    @ObservedObject var session: PDFSession
    var zoom: ReaderZoom? = nil
    var selectionActions = PDFSelectionActions()

    @MainActor final class Coordinator { let citations = PDFCitationHighlights() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFSelectionView(); view.selectionActions = selectionActions
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
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        ReaderScrolling.configure(view)
        (view as? PDFSelectionView)?.selectionActions = selectionActions
        if let selectionView = view as? PDFSelectionView { configureDrawing(selectionView) }
        let mode: PDFDisplayMode = session.twoPage ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != mode { view.displayMode = mode }
        if view.displaysAsBook { view.displaysAsBook = false }
        context.coordinator.citations.update(session.activeCitation)
        if session.activeCitation != nil { view.highlightedSelections = [] }
        guard view.document !== session.document else { return }
        view.document = session.document
        session.applyLibraryDestination()
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
            view.selectionActions = PDFSelectionActions(); view.editNote = nil
        }
        view.document?.cancelFindString()
        view.pageOverlayViewProvider = nil; coordinator.citations.update(nil)
        view.document = nil
    }
}
