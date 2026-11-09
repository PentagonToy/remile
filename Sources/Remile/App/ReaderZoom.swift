import SwiftUI
import PDFKit
import WebKit

@MainActor
final class ReaderZoom: ObservableObject {
    static let preference = "reader.markdownZoom"
    @Published private(set) var scale: CGFloat
    @Published private(set) var wide = false
    private weak var pdf: PDFView?
    private weak var web: WKWebView?
    private var observers: [NSObjectProtocol] = []
    private var fitting: (mode: PageFit, centre: Bool)?
    private var layoutObserver: NSObjectProtocol?
    private var lastPDFScale: CGFloat?
    init(text: Bool = false) {
        let saved = UserDefaults.standard.double(forKey: Self.preference)
        scale = text && saved > 0 ? min(3, max(0.5, saved / 100)) : 1
    }
    var label: String { "\(Int((scale * 100).rounded()))%" }
    func attach(_ view: PDFView) {
        guard pdf !== view else { return }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver); self.layoutObserver = nil }
        let retainedScale = pdf?.scaleFactor ?? lastPDFScale
        pdf = view
        if let retainedScale, fitting == nil {
            view.autoScales = false
            view.scaleFactor = retainedScale
            publishPDFScaleAfterLayout(in: view)
        } else { fitting = fitting ?? (.page, false) }
        view.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, self.pdf === view else { return }
                self.publishPDFScale(view.scaleFactor)
            }
        })
        completePendingFit(in: view)
        if fitting != nil {
            observeLayout(of: view)
            Task { @MainActor [weak self, weak view] in
                if let view { self?.completePendingFit(in: view) }
            }
        }
    }

    func attach(_ view: WKWebView) {
        web = view
        if view.pageZoom != scale { view.pageZoom = scale }
    }
    func step(_ direction: CGFloat, fine: Bool = false) { change(scale + direction * (fine ? 0.02 : 0.1)) }
    func change(_ value: CGFloat) {
        fitting = nil; scale = min(5, max(0.25, value))
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver); self.layoutObserver = nil }
        if let pdf { pdf.autoScales = false; pdf.scaleFactor = scale; lastPDFScale = pdf.scaleFactor }
        web?.pageZoom = scale
    }
    private func observeLayout(of view: PDFView) {
        guard layoutObserver == nil else { return }
        layoutObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                if let view { self?.completePendingFit(in: view) }
            }
        }
    }
    func fitReadingWidth(wide width: Bool) {
        wide = width
        change(1)
    }
    func fit(_ mode: PageFit) {
        fitting = (mode, true)
        guard let pdf else { return }
        completePendingFit(in: pdf)
        if fitting != nil { observeLayout(of: pdf) }
    }
    /// Complete a pending fit once the document and its viewport are ready.
    func completePendingFit(in pdf: PDFView) {
        guard self.pdf === pdf, let (mode, shouldCentre) = fitting,
              let document = pdf.document, document.pageCount > 0, !document.isLocked else { return }
        pdf.layoutDocumentView()
        let clip = pdf.documentView?.enclosingScrollView?.contentView
        let visible = clip.map { pdf.convert($0.bounds, from: $0) } ?? pdf.bounds
        let viewport = visible.size
        let nearest = pdf.page(for: NSPoint(x: visible.midX, y: visible.midY), nearest: true)
        guard viewport.width > 32, viewport.height > 24,
              let page = (shouldCentre ? nearest ?? pdf.currentPage : pdf.currentPage ?? nearest) ?? document.page(at: 0) else { return }
        var pages = [page]
        if pdf.displayMode == .twoUp || pdf.displayMode == .twoUpContinuous {
            let index = document.index(for: page)
            if index != NSNotFound {
                let start = pdf.displaysAsBook ? (index == 0 ? -1 : 1 + ((index - 1) / 2) * 2) : (index / 2) * 2
                pages = [start, start + 1].filter { $0 >= 0 && $0 < document.pageCount }.compactMap { document.page(at: $0) }
            }
        }
        let rectangles = pages.map { pdf.convert($0.bounds(for: pdf.displayBox), from: $0) }
        let spread = rectangles.dropFirst().reduce(rectangles.first ?? .zero) { $0.union($1) }
        guard pdf.scaleFactor > 0 else { return }
        let paper = CGSize(width: spread.width / pdf.scaleFactor, height: spread.height / pdf.scaleFactor)
        guard paper.width > 0, paper.height > 0 else { return }
        let x = (viewport.width - 32) / paper.width
        let y = max(1, viewport.height - 24) / paper.height
        let target = min(5, max(0.1, mode.scale(width: x, height: y)))
        fitting = nil
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver); self.layoutObserver = nil }
        pdf.autoScales = false
        if abs(pdf.scaleFactor - target) > 0.001 { pdf.scaleFactor = target }
        pdf.layoutDocumentView()
        if shouldCentre {
            pdf.go(to: page)
            centre(pages, in: pdf, vertically: mode != .width)
            publishPDFScale(pdf.scaleFactor)
        } else {
            publishPDFScaleAfterLayout(in: pdf)
        }
    }
    private func publishPDFScale(_ value: CGFloat) {
        lastPDFScale = value
        if scale != value { scale = value }
    }
    private func publishPDFScaleAfterLayout(in pdf: PDFView) {
        lastPDFScale = pdf.scaleFactor
        Task { @MainActor [weak self, weak pdf] in
            guard let self, let pdf, self.pdf === pdf else { return }
            self.publishPDFScale(pdf.scaleFactor)
        }
    }
    private func centre(_ pages: [PDFPage], in pdf: PDFView, vertically: Bool) {
        guard let scroll = pdf.documentView?.enclosingScrollView, let first = pages.first else { return }
        let clip = scroll.contentView
        let spread = pages.dropFirst().reduce(pdf.convert(first.bounds(for: pdf.displayBox), from: first)) {
            $0.union(pdf.convert($1.bounds(for: pdf.displayBox), from: $1))
        }
        let page = clip.convert(spread, from: pdf)
        var bounds = clip.bounds
        bounds.origin.x = page.midX - bounds.width / 2
        if vertically, page.height <= bounds.height { bounds.origin.y = page.midY - bounds.height / 2 }
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver); if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) } }
}

struct ReaderZoomControls: View {
    @ObservedObject var zoom: ReaderZoom
    var text = false
    var body: some View {
        HStack(spacing: 0) {
            Button { zoom.step(-1) } label: { SymbolIcon(systemName: "minus").frame(width: RemileControl.toolHit, height: RemileControl.toolHit).contentShape(Rectangle()) }
                .remileHelp("Zoom out 10 percentage points (⌘−: fine)").accessibilityLabel("Zoom out")
            Menu {
                ReaderZoomMenuItems(zoom: zoom, text: text)
            } label: { Text(zoom.label).monospacedDigit().frame(width: 70, height: 32) }
                .menuStyle(.borderlessButton).tint(RemileStyle.ink).fixedSize().remileHelp("Zoom percentage and fit options")
            Button { zoom.step(1) } label: { SymbolIcon(systemName: "plus").frame(width: RemileControl.toolHit, height: RemileControl.toolHit).contentShape(Rectangle()) }
                .remileHelp("Zoom in 10 percentage points (⌘+: fine)").accessibilityLabel("Zoom in")
            Button {
                if text { zoom.fitReadingWidth(wide: true) } else { zoom.fit(.height) }
            } label: {
                Text("Fit").frame(width: 42, height: RemileControl.toolHit).contentShape(Rectangle())
            }.remileHelp(text ? "Fit width (⌘0)" : "Fit height (⌘0)").keyboardShortcut("0")
        }.buttonStyle(RemileToolStyle()).font(RemileType.control).tint(.primary).fixedSize()
            .accessibilityElement(children: .contain)
            .background {
                Group {
                    Button("") { zoom.step(-1, fine: true) }.keyboardShortcut("-")
                    Button("") { zoom.step(1, fine: true) }.keyboardShortcut("+")
                    Button("") { zoom.step(1, fine: true) }.keyboardShortcut("=")
                }.hidden().allowsHitTesting(false).accessibilityHidden(true)
            }
            .padding(.horizontal, 2)
            .foregroundStyle(.primary)

    }
}

struct ReaderZoomMenuItems: View {
    @ObservedObject var zoom: ReaderZoom
    var text = false
    var body: some View {
        Button("Zoom in") { zoom.step(1) }
        Button("Zoom out") { zoom.step(-1) }
        Divider()
        Button("Actual size · 100%") { zoom.change(1) }
        if text {
            Button("Reading width") { zoom.fitReadingWidth(wide: false) }
            Button("Fit width") { zoom.fitReadingWidth(wide: true) }
        } else {
            Button("Fit height") { zoom.fit(.height) }
            Button("Fit width") { zoom.fit(.width) }
        }
        Divider()
        ForEach([50, 75, 100, 125, 150, 200], id: \.self) { percent in
            Button("\(percent)%") { zoom.change(CGFloat(percent) / 100) }
        }
    }
}
