import SwiftUI
import AppKit

/// Sizes the import sheet from its parent workspace, with room around small screens.
struct OverleafImportSizing: NSViewRepresentable {
    let resized: (CGSize) -> Void
    static func fit(parent: CGSize, screen: CGSize) -> CGSize {
        let width = min(max(320, parent.width - 24), max(320, screen.width - 48), min(1160, max(560, parent.width * 0.88)))
        let height = min(max(320, parent.height - 48), max(320, screen.height - 96), min(780, max(460, parent.height * 0.78)))
        return CGSize(width: width.rounded(), height: height.rounded())
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.resized = resized; return view }
    func updateNSView(_ view: Probe, context: Context) { view.resized = resized; DispatchQueue.main.async { [weak view] in view?.report() } }
    final class Probe: NSView {
        var resized: ((CGSize) -> Void)?
        private weak var parent: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var lastSize = CGSize.zero
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { [weak self] in self?.report() } }
        func report() {
            guard let host = window?.sheetParent else { return }
            if parent !== host {
                observers.forEach(NotificationCenter.default.removeObserver); observers = []; parent = host
                for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: host, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.report() } })
                }
            }
            let next = OverleafImportSizing.fit(parent: host.contentLayoutRect.size, screen: host.screen?.visibleFrame.size ?? host.frame.size)
            guard next != lastSize else { return }; lastSize = next; resized?(next)
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
