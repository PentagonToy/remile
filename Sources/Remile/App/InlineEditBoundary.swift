import SwiftUI
import AppKit

/// Non-focusable surfaces must also dismiss an inline editor when clicked.
struct InlineEditBoundary: NSViewRepresentable {
    let outside: () -> Void
    final class Region: NSView {
        var outside: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    DispatchQueue.main.async { [weak self] in self?.outside?() }
                }
                return event
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> Region { let view = Region(); view.outside = outside; return view }
    func updateNSView(_ view: Region, context: Context) { view.outside = outside }
    static func dismantleNSView(_ view: Region, coordinator: ()) { view.outside = nil }
}
