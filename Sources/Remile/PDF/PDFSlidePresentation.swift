import AppKit
import PDFKit
import Combine

/// A separate canvas shares the open PDF without changing the reader's zoom or layout.
@MainActor final class PDFSlidePresentation: ObservableObject {
    private(set) var view: PDFSlideView?
    private weak var sourceWindow: NSWindow?
    private var completed: ((Int) -> Void)?

    func start(document: PDFDocument, page: Int, completed: @escaping (Int) -> Void) {
        guard view == nil, !document.isLocked, document.pageCount > 0,
              let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        sourceWindow = NSApp.keyWindow
        self.completed = completed
        let view = PDFSlideView(frame: screen.frame)
        self.view = view
        view.document = document
        view.go(to: document.page(at: min(max(0, page - 1), document.pageCount - 1))!)
        view.finish = { [weak self] in self?.finish() }
        guard view.enterFullScreenMode(screen, withOptions: [.fullScreenModeAllScreens: false]) else { finish(); return }
        view.layoutDocumentView()
        view.window?.makeFirstResponder(view)
    }

    func finish() {
        guard let view else { return }
        self.view = nil
        let page = view.currentPage.flatMap { view.document?.index(for: $0) }.map { $0 + 1 } ?? 1
        if view.isInFullScreenMode { view.exitFullScreenMode(options: nil) }
        view.document = nil; view.finish = nil
        let completed = completed; self.completed = nil
        completed?(page)
        if sourceWindow?.isVisible == true { sourceWindow?.makeKeyAndOrderFront(nil) }
        sourceWindow = nil
    }
}

@MainActor final class PDFSlideView: PDFView {
    var finish: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        displayMode = .singlePage
        displayDirection = .horizontal
        displaysPageBreaks = false
        backgroundColor = .black
        autoScales = true
        setAccessibilityLabel("PDF slide view")
        setAccessibilityHelp("Click or press Right for the next page. Right-click or press Left for the previous page. Press Escape to return to reading.")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Next slide", handler: { [weak self] in self?.goToNextPage(nil); return true }),
            NSAccessibilityCustomAction(name: "Previous slide", handler: { [weak self] in self?.goToPreviousPage(nil); return true }),
            NSAccessibilityCustomAction(name: "Exit slide view", handler: { [weak self] in self?.finish?(); return true })
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { goToNextPage(nil) }
    override func rightMouseDown(with event: NSEvent) { goToPreviousPage(nil) }
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 53: finish?()
        case 123, 126, 116: goToPreviousPage(nil)
        case 124, 125, 121: goToNextPage(nil)
        case 49: if event.modifierFlags.contains(.shift) { goToPreviousPage(nil) } else { goToNextPage(nil) }
        default: super.keyDown(with: event)
        }
    }
}
