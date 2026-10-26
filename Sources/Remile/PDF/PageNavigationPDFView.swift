import AppKit
import PDFKit

/// Horizontal arrows turn pages. Vertical arrows remain native continuous scrolling.
@MainActor class PageNavigationPDFView: PDFView {
    private var pageKeys: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pageKeys { NSEvent.removeMonitor(pageKeys); self.pageKeys = nil }
        guard window != nil else { return }
        pageKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window, let focused = self.window?.firstResponder as? NSView,
                      focused === self || focused.isDescendant(of: self), !(focused is NSControl),
                      !((focused as? NSTextView)?.isEditable == true) else { return false }
                return self.turnPage(with: event)
            }
            return handled ? nil : event
        }
    }
    override func keyDown(with event: NSEvent) {
        if !turnPage(with: event) { super.keyDown(with: event) }
    }
    @discardableResult func turnPage(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              event.keyCode == 123 || event.keyCode == 124, document != nil else { return false }
        prepareForKeyboardPageChange()
        if event.keyCode == 123 { goToPreviousPage(nil) } else { goToNextPage(nil) }
        return true
    }
    func prepareForKeyboardPageChange() {}
    deinit { if let pageKeys { NSEvent.removeMonitor(pageKeys) } }
}
