import SwiftUI
import AppKit

/// Non-focusable surfaces must also finish an inline edit when clicked.
struct InlineEditBoundary: NSViewRepresentable {
    let outside: () -> Void
    let cancel: (() -> Void)?
    init(cancel: (() -> Void)? = nil, outside: @escaping () -> Void) { self.cancel = cancel; self.outside = outside }
    final class Region: NSView {
        var outside: (() -> Void)?
        var cancel: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window || (event.type == .keyDown && NSApp.keyWindow === window) else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53, let cancel = self.cancel { cancel(); return nil }
                    return event
                }
                if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    let outside = self.outside
                    DispatchQueue.main.async { outside?() }
                }
                return event
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> Region { let view = Region(); view.outside = outside; view.cancel = cancel; return view }
    func updateNSView(_ view: Region, context: Context) { view.outside = outside; view.cancel = cancel }
    static func dismantleNSView(_ view: Region, coordinator: ()) { view.outside = nil; view.cancel = nil }
}
