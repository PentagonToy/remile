import SwiftUI
import PDFKit

@MainActor final class TeXPDFController: NSObject, ObservableObject {
    weak var view: PDFView?
    @Published private(set) var page = 0
    @Published private(set) var pages = 0
    private var pageObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private var pendingClick: NSEvent?
    private var pendingJump: TeXProject.PDFJump?
    var reverse: (TeXSync.PDFLocation) -> Void = { _ in }
    private var lastJump: UUID?
    private var highlight: Task<Void, Never>?
    func attach(_ view: PDFView) {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        highlight?.cancel(); lastJump = nil
        self.view = view
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePage() }
        }
        updatePage()
        // PDFKit's internal text view owns selection gestures. Observe its event
        // without competing with or consuming the native word-selection gesture.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.observeSelectionGesture(event) }
            return event
        }
    }
    func detach() {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver); self.pageObserver = nil }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        highlight?.cancel(); pendingJump = nil; pendingClick = nil; view = nil
    }
    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        highlight?.cancel()
    }
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
    func observeSelectionGesture(_ event: NSEvent) {
        if event.type == .leftMouseDragged {
            if let down = pendingClick, hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 5 { pendingClick = nil }
            return
        }
        guard event.window === view?.window else { return }
        if event.type == .leftMouseDown { pendingClick = event.clickCount == 2 ? event : nil }
        else if event.type == .leftMouseUp {
            defer { pendingClick = nil }
            if let pendingClick { _ = handleDoubleClick(pendingClick) }
        }
    }
    @discardableResult func handleDoubleClick(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 2, let view,
              let window = view.window, event.window === window else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.visibleRect.contains(point), let hit = view.hitTest(view.convert(point, to: view.superview)), !(hit is NSScroller),
              let page = view.page(for: point, nearest: false), let document = view.document, page.document === document,
              let location = location(at: point) else { return false }
        guard let root = window.contentView,
              let top = root.hitTest(root.convert(event.locationInWindow, from: nil)), top === view || top.isDescendant(of: view) else { return false }
        reverse(location)
        return true
    }
    private func location(at point: NSPoint) -> TeXSync.PDFLocation? {
        guard let view, let page = view.page(for: point, nearest: true), let document = view.document else { return nil }
        let local = view.convert(point, to: page), box = page.bounds(for: .mediaBox)
        var result = TeXSync.PDFLocation(page: document.index(for: page) + 1, x: max(0, local.x - box.minX), y: max(0, box.maxY - local.y))
        var offset = page.characterIndex(at: local)
        // PDF text-stream order can disagree with the glyph under the pointer.
        // Use PDFKit's selected word and its page bounds before refining a source token.
        if let word = page.selectionForWord(at: local)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty,
           let text = page.string as NSString?, text.length <= 100_000 {
            var range = NSRange(location: 0, length: text.length), matched: Int?
            while range.length > 0 {
                let found = text.range(of: word, options: [], range: range)
                guard found.location != NSNotFound else { break }
                if page.selection(for: found)?.bounds(for: page).insetBy(dx: -2, dy: -2).contains(local) == true { matched = found.location; break }
                range = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            }
            guard let matched else { return result }
            offset = matched
        } else { return result }
        if offset >= 0, let text = page.string as NSString?, text.length <= 100_000, offset < text.length {
            let start = max(0, offset - 180), count = min(360, text.length - start)
            result.hint = .init(text: text.substring(with: NSRange(location: start, length: count)), offset: offset - start)
        }
        return result
    }
    func currentLocation() -> TeXSync.PDFLocation? {
        guard let view else { return nil }
        if let selection = view.currentSelection, let page = selection.pages.first, let document = view.document {
            let bounds = selection.bounds(for: page), box = page.bounds(for: .mediaBox)
            return location(at: view.convert(NSPoint(x: bounds.midX, y: bounds.midY), from: page))
        }
        return location(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
    }
    func show(_ jump: TeXProject.PDFJump?) {
        if let jump, jump.id != lastJump { pendingJump = jump }
        showPendingJump()
    }
    func showPendingJump() {
        guard let jump = pendingJump, jump.id != lastJump, let view, view.window != nil, view.bounds.width > 0, view.bounds.height > 0,
              view.documentView?.bounds.isEmpty == false,
              let page = view.document?.page(at: jump.location.page - 1) else { return }
        pendingJump = nil
        lastJump = jump.id
        let box = page.bounds(for: .mediaBox), point = NSPoint(x: box.minX + jump.location.x, y: box.maxY - jump.location.y)
        let rect = NSRect(x: max(box.minX, point.x - 6), y: point.y - 12, width: min(460, box.width - max(0, point.x - box.minX)), height: 28)
        view.go(to: rect, on: page)
        highlight?.cancel(); highlight = nil
        view.clearSelection(); view.highlightedSelections = nil
        if let hint = jump.location.hint, let text = page.string, text.utf16.count <= 16_000,
           let range = TeXSync.refine(.init(file: "", line: 0), source: text, hint: hint).range,
           let selection = page.selection(for: range),
           abs(selection.bounds(for: page).midY - point.y) < 140,
           abs(selection.bounds(for: page).midX - point.x) < 300 {
            view.go(to: selection.bounds(for: page).insetBy(dx: -12, dy: -20), on: page)
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

@MainActor final class TeXPreviewPDFView: PageNavigationPDFView {
    weak var navigation: TeXPDFController?
    override func layout() { super.layout(); navigation?.showPendingJump() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); navigation?.showPendingJump() }
}

struct TeXPDFPreview: NSViewRepresentable {
    let document: PDFDocument
    let zoom: ReaderZoom
    let controller: TeXPDFController
    let jump: TeXProject.PDFJump?
    func makeCoordinator() -> TeXPDFController { controller }
    func makeNSView(context: Context) -> PDFView {
        let view = TeXPreviewPDFView(); view.navigation = controller; view.autoScales = true; view.displayMode = .singlePageContinuous; view.document = document
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
    static func dismantleNSView(_ view: PDFView, coordinator: TeXPDFController) { view.document = nil; if coordinator.view === view { coordinator.detach() } }
}
