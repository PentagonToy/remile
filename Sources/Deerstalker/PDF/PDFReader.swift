import PDFKit
import SwiftUI

struct PDFReader: NSViewRepresentable {
    @ObservedObject var session: PDFSession
    var zoom: ReaderZoom? = nil

    @MainActor final class Coordinator { let citations = PDFCitationHighlights() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.pageOverlayViewProvider = context.coordinator.citations
        context.coordinator.citations.update(session.activeCitation)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.document = session.document
        session.attach(view)
        zoom?.attach(view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.citations.update(session.activeCitation)
        if session.activeCitation != nil { view.highlightedSelections = [] }
        guard view.document !== session.document else { return }
        view.document = session.document
        session.applyLibraryDestination()
        context.coordinator.citations.update(session.activeCitation)
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        view.document?.cancelFindString()
        view.pageOverlayViewProvider = nil; coordinator.citations.update(nil)
        view.document = nil
    }
}
