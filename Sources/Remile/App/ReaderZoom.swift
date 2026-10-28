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
    private var fitting: Bool? // true: width, false: page, nil: manual
    private struct FitGeometry: Equatable {
        let viewport: CGSize
        let page: CGSize
        let width: Bool
        let mode: PDFDisplayMode
    }
    private var lastFit: FitGeometry?
    init(text: Bool = false) {
        let saved = UserDefaults.standard.double(forKey: Self.preference)
        scale = text && saved > 0 ? min(3, max(0.5, saved / 100)) : 1
    }
    var label: String { "\(Int((scale * 100).rounded()))%" }
    func attach(_ view: PDFView) {
        guard pdf !== view else { return }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        pdf = view; scale = view.scaleFactor; lastFit = nil
        if fitting == nil { fitting = false }
        fit(width: fitting ?? false)
        view.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, self.pdf === view else { return }; self.scale = view.scaleFactor
            }
        })
        for name in [NSView.frameDidChangeNotification, Notification.Name.PDFViewPageChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self, weak view] _ in
                let selecting = NSEvent.pressedMouseButtons & 1 != 0
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.pdf === view else { return }
                    self.updateFitForLayout(pageChanged: name == .PDFViewPageChanged, selecting: selecting)
                }
            })
        }
    }
    func attach(_ view: WKWebView) { web = view; view.pageZoom = scale }
    func step(_ direction: CGFloat, fine: Bool = false) { change(scale + direction * (fine ? 0.02 : 0.1)) }
    func change(_ value: CGFloat) {
        fitting = nil; lastFit = nil; scale = min(5, max(0.25, value))
        if let pdf { pdf.autoScales = false; pdf.scaleFactor = scale }
        web?.pageZoom = scale
    }
    /// Selection can change PDFKit's current page without a reader navigation action.
    func updateFitForLayout(pageChanged: Bool, selecting: Bool) {
        guard let width = fitting, !(pageChanged && selecting) else { return }
        applyFit(width: width, force: false)
    }
    func fit(width: Bool) { applyFit(width: width, force: true) }
    private func applyFit(width: Bool, force: Bool) {
        wide = width
        guard let pdf, let page = pdf.currentPage else { change(1); return }
        fitting = width
        let bounds = page.bounds(for: pdf.displayBox)
        let rotated = abs(page.rotation % 180) == 90
        let unitWidth = rotated ? bounds.height : bounds.width
        let unitHeight = rotated ? bounds.width : bounds.height
        guard unitWidth > 0, unitHeight > 0, pdf.bounds.width > 32, pdf.bounds.height > 24 else { return }
        let geometry = FitGeometry(viewport: pdf.bounds.size, page: CGSize(width: unitWidth, height: unitHeight), width: width, mode: pdf.displayMode)
        guard force || geometry != lastFit else { return }
        lastFit = geometry
        let x = max(1, pdf.bounds.width - 32) / unitWidth
        let y = max(1, pdf.bounds.height - 24) / unitHeight
        let target = min(5, max(0.1, width ? x : min(x, y)))
        pdf.autoScales = false
        if abs(pdf.scaleFactor - target) > 0.001 { pdf.scaleFactor = target }
        scale = pdf.scaleFactor
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
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
