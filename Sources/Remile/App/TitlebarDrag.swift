import AppKit

/// Handle blank native title-bar space without covering toolbar controls or document content.
@MainActor final class TitlebarDrag {
    private weak var window: NSWindow?
    private var monitor: Any?
    init(window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let window = self?.window, event.window === window, window.isMovable,
                  window.attachedSheet == nil, event.clickCount == 1 else { return event }
            let point = event.locationInWindow
            guard point.y >= window.contentLayoutRect.maxY, point.y < window.frame.height - 4,
                  point.x >= 4, point.x < window.frame.width - 4 else { return event }
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .toolbarButton, .documentIconButton, .documentVersionsButton]
            let controls: [NSView] = buttons.compactMap { window.standardWindowButton($0) } + (window.toolbar?.visibleItems ?? []).compactMap(\.view)
            for control in controls where control.window === window && !control.isHidden {
                if control.convert(control.bounds, to: nil).insetBy(dx: -8, dy: -4).contains(point) { return event }
            }
            window.performDrag(with: event)
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
