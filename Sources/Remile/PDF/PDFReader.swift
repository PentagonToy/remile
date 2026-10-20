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
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        (view as? PDFSelectionView)?.selectionActions = PDFSelectionActions()
        view.document?.cancelFindString()
        view.pageOverlayViewProvider = nil; coordinator.citations.update(nil)
        view.document = nil
    }
}
