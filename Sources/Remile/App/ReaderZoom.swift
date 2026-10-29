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
    private var fitting: Bool? // Pending one-shot fit until the initial viewport exists.
    private var layoutObserver: NSObjectProtocol?
    private var hasAttachedPDF = false
    init(text: Bool = false) {
        let saved = UserDefaults.standard.double(forKey: Self.preference)
        scale = text && saved > 0 ? min(3, max(0.5, saved / 100)) : 1
    }
    var label: String { "\(Int((scale * 100).rounded()))%" }
    func attach(_ view: PDFView) {
        guard pdf !== view else { return }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver); self.layoutObserver = nil }
        let restoring = hasAttachedPDF && fitting == nil
        hasAttachedPDF = true; pdf = view
        if restoring { view.autoScales = false; view.scaleFactor = scale }
        else { scale = view.scaleFactor; fit(width: fitting ?? false) }
        view.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, self.pdf === view else { return }; self.scale = view.scaleFactor
            }
        })
        if fitting != nil {
            layoutObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateFitForLayout(pageChanged: false, selecting: false) }
            }
        }
    }

    func attach(_ view: WKWebView) { web = view; view.pageZoom = scale }
    func step(_ direction: CGFloat, fine: Bool = false) { change(scale + direction * (fine ? 0.02 : 0.1)) }
    func change(_ value: CGFloat) {
        fitting = nil; scale = min(5, max(0.25, value))
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver); self.layoutObserver = nil }
        if let pdf { pdf.autoScales = false; pdf.scaleFactor = scale }
        web?.pageZoom = scale
    }
    /// Resizing only completes an initial fit that was requested before layout.
    func updateFitForLayout(pageChanged: Bool, selecting: Bool) {
        guard let width = fitting, !pageChanged, !selecting else { return }
        applyFit(width: width)
    }
    func fit(width: Bool) { applyFit(width: width) }
    private func applyFit(width: Bool) {
        wide = width
        guard let pdf else { change(1); return }
        fitting = width
        pdf.layoutDocumentView()
        let clip = pdf.documentView?.enclosingScrollView?.contentView
        let visible = clip.map { pdf.convert($0.bounds, from: $0) } ?? pdf.bounds
        let viewport = visible.size
        guard viewport.width > 32, viewport.height > 24,
              let page = pdf.page(for: NSPoint(x: visible.midX, y: visible.midY), nearest: true) ?? pdf.currentPage ?? pdf.document?.page(at: 0) else { return }
        var pages = [page]
        if (pdf.displayMode == .twoUp || pdf.displayMode == .twoUpContinuous), let document = pdf.document {
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
        guard paper.width > 0, paper.height > 0, viewport.width > 32, viewport.height > 24 else { return }
        let x = max(1, viewport.width - 32) / paper.width
        let y = max(1, viewport.height - 24) / paper.height
        let target = min(5, max(0.1, width ? x : min(x, y)))
        fitting = nil
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver); self.layoutObserver = nil }
        pdf.autoScales = false
        if abs(pdf.scaleFactor - target) > 0.001 { pdf.scaleFactor = target }
        pdf.layoutDocumentView()
        pdf.go(to: page)
        scale = pdf.scaleFactor
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
            Button { zoom.fit(width: text) } label: { Text("Fit").frame(width: 42, height: 32).contentShape(Rectangle()) }.remileHelp(text ? "Fit reading width" : "Fit the whole page (⌘0)").keyboardShortcut("0")
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
        Button(text ? "Reading width" : "Fit page") { zoom.fit(width: false) }
        Button("Fit width") { zoom.fit(width: true) }
        Divider()
        ForEach([50, 75, 100, 125, 150, 200], id: \.self) { percent in
            Button("\(percent)%") { zoom.change(CGFloat(percent) / 100) }
        }
    }
}
