import AppKit

/// Blank title-bar gestures never cover controls or document content.
@MainActor final class TitlebarDrag {
    private weak var window: NSWindow?
    private var monitor: Any?
    init(window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isMovable,
              window.attachedSheet == nil, (1...2).contains(event.clickCount) else { return false }
        let point = event.locationInWindow
        guard point.y >= window.contentLayoutRect.maxY, point.y < window.frame.height - 4,
              point.x >= 4, point.x < window.frame.width - 4 else { return false }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .toolbarButton, .documentIconButton, .documentVersionsButton]
        let controls: [NSView] = buttons.compactMap { window.standardWindowButton($0) } + (window.toolbar?.visibleItems ?? []).compactMap(\.view)
        for control in controls where control.window === window && !control.isHidden {
            if control.convert(control.bounds, to: nil).insetBy(dx: -8, dy: -4).contains(point) { return false }
        }
        if event.clickCount == 2 {
            guard window.styleMask.contains(.resizable), !window.styleMask.contains(.fullScreen) else { return false }
            window.performZoom(nil)
        } else { window.performDrag(with: event) }
        return true
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
