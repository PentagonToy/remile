import SwiftUI
import PDFKit

@MainActor final class TeXPDFController: NSObject, ObservableObject, NSGestureRecognizerDelegate {
    weak var view: PDFView?
    @Published private(set) var page = 0
    @Published private(set) var pages = 0
    private var pageObserver: NSObjectProtocol?
    var reverse: (TeXSync.PDFLocation) -> Void = { _ in }
    private var lastJump: UUID?
    private var highlight: Task<Void, Never>?
    func attach(_ view: PDFView) {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        self.view = view
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePage() }
        }
        updatePage()
        let click = NSClickGestureRecognizer(target: self, action: #selector(doubleClick(_:))); click.numberOfClicksRequired = 2; click.delaysPrimaryMouseButtonEvents = false; click.delegate = self
        view.addGestureRecognizer(click)
    }
    deinit { if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) } }
    func updatePage() {
        let count = view?.document?.pageCount ?? 0
        let number = view?.currentPage.flatMap { view?.document?.index(for: $0) }.map { $0 + 1 } ?? (count > 0 ? 1 : 0)
        if pages != count { pages = count }
        if page != number { page = number }
    }
    func go(_ number: Int) {
        guard number > 0, let target = view?.document?.page(at: number - 1) else { return }
        view?.go(to: target); updatePage()
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
    @objc private func doubleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let view, let location = location(at: recognizer.location(in: view)) else { return }
        reverse(location)
    }
    private func location(at point: NSPoint) -> TeXSync.PDFLocation? {
        guard let view, let page = view.page(for: point, nearest: true), let document = view.document else { return nil }
        let local = view.convert(point, to: page), box = page.bounds(for: .mediaBox)
        return .init(page: document.index(for: page) + 1, x: max(0, local.x - box.minX), y: max(0, box.maxY - local.y))
    }
    func currentLocation() -> TeXSync.PDFLocation? {
        guard let view else { return nil }
        if let selection = view.currentSelection, let page = selection.pages.first, let document = view.document {
            let bounds = selection.bounds(for: page), box = page.bounds(for: .mediaBox)
            return .init(page: document.index(for: page) + 1, x: bounds.midX - box.minX, y: box.maxY - bounds.midY)
        }
        return location(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
    }
    func show(_ jump: TeXProject.PDFJump?) {
        guard let jump, jump.id != lastJump, let view, let page = view.document?.page(at: jump.location.page - 1) else { return }
        lastJump = jump.id
        let box = page.bounds(for: .mediaBox), point = NSPoint(x: box.minX + jump.location.x, y: box.maxY - jump.location.y)
        let rect = NSRect(x: max(box.minX, point.x - 6), y: point.y - 12, width: min(460, box.width - max(0, point.x - box.minX)), height: 28)
        view.go(to: rect, on: page)
        if let selection = page.selection(for: rect) {
            selection.color = NSColor(RemileStyle.accent).withAlphaComponent(0.35); view.highlightedSelections = [selection]
            highlight?.cancel(); highlight = Task { @MainActor [weak view] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let view else { return }
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    for step in 1...18 {
                        selection.color = NSColor(RemileStyle.accent).withAlphaComponent(0.35 * (1 - Double(step) / 18))
                        view.highlightedSelections = [selection]
                        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    }
                }
                view.highlightedSelections = nil
            }
        }
    }
}

struct TeXPDFPreview: NSViewRepresentable {
    let document: PDFDocument
    let zoom: ReaderZoom
    let controller: TeXPDFController
    let jump: TeXProject.PDFJump?
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.document = document
        ReaderScrolling.configure(view); zoom.attach(view); controller.attach(view); return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            let page = view.currentPage.map { view.document?.index(for: $0) ?? 0 } ?? 0; view.document = document
            if let target = document.page(at: min(page, max(0, document.pageCount - 1))) { view.go(to: target) }
            Task { @MainActor in controller.updatePage() }
        }
        ReaderScrolling.configure(view); controller.show(jump)
    }
}
