import AppKit
import PDFKit
import QuartzCore

/// An owned selection, captured when the menu opens rather than when an action runs.
@MainActor
struct PDFSelectionContext {
    let document: PDFDocument
    let selection: PDFSelection
    let text: String
    let pageIndices: [Int]

    init?(selection: PDFSelection?, document: PDFDocument?) {
        guard let document, !document.isLocked, let original = selection,
              let selection = original.copy() as? PDFSelection,
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !selection.pages.isEmpty, selection.pages.allSatisfy({ $0.document === document }) else { return nil }
        let indices = selection.pages.map { document.index(for: $0) }
        guard indices.allSatisfy({ $0 != NSNotFound && $0 >= 0 && $0 < document.pageCount }) else { return nil }
        self.document = document; self.selection = selection; self.text = text
        pageIndices = indices.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    func isValid(in view: PDFView) -> Bool {
        view.document === document && !document.isLocked && !selection.pages.isEmpty &&
        selection.pages.allSatisfy { page in
            page.document === document && document.index(for: page) != NSNotFound
        } && selection.pages.map { document.index(for: $0) }.reduce(into: [Int]()) {
            if !$0.contains($1) { $0.append($1) }
        } == pageIndices
    }
}

/// Callers own persistence and presentation. These actions never write a PDF themselves.
@MainActor
struct PDFSelectionActions {
    var highlight: ((PDFSelectionContext, HighlightColor) -> Void)?
    var addNote: ((PDFSelectionContext) -> Void)?
    var ask: ((PDFSelectionContext) -> Void)?
    var translate: ((PDFSelectionContext) -> Void)?
    var canAnnotate: ((PDFSelectionContext) -> Bool)?
    var removeHighlight: ((PDFDocument, PDFAnnotation) -> Void)?
    var removeNote: ((PDFDocument, PDFAnnotation) -> Void)?
}

/// Reader and Search use the same explicit native menu, without swizzling PDFKit.
@MainActor
final class PDFSelectionView: PageNavigationPDFView {
    var openPDFs: (([URL]) -> Bool)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }
    static func droppedPDFs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, urls.count <= 32, urls.allSatisfy({ $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }) else { return [] }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if openPDFs != nil, !Self.droppedPDFs(from: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if openPDFs != nil, !Self.droppedPDFs(from: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if openPDFs != nil, !Self.droppedPDFs(from: sender.draggingPasteboard).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.droppedPDFs(from: sender.draggingPasteboard)
        if !urls.isEmpty, let openPDFs { return openPDFs(urls) }
        return super.performDragOperation(sender)
    }
    private lazy var imageDrag = PDFImageDrag(view: self)
    private lazy var contentMenu = PDFContentMenu(view: self)
    override var document: PDFDocument? {
        willSet { if newValue !== document { contentMenu.cancel(); imageDrag.cancel() } }
    }
    var selectionActions = PDFSelectionActions()
    var drawingTool: PDFDrawingTool? { didSet { if oldValue != drawingTool { cancelDrawing(); imageDrag.cancel(); window?.invalidateCursorRects(for: self) } } }
    var drawingColor: NSColor = .systemRed
    var editNote: ((PDFAnnotation) -> Void)?
    var beginDrawing: (() -> Bool)?
    var commitDrawing: ((PDFPage, PDFAnnotation) -> Void)?
    var finishDrawing: (() -> Void)?
    private var drawingPage: PDFPage?
    private var drawingPoints = [CGPoint]()
    private var previewLayer: CAShapeLayer?
    private var previewPath: CGMutablePath?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        guard target != nil, !(target is NSScroller) else { return target }
        if target is NSControl { return target }
        if drawingTool != nil { return self }
        if editNote != nil {
            let location = convert(point, from: superview)
            if let page = page(for: location, nearest: false),
               page.annotations.contains(where: { $0.type == "Text" && $0.bounds.contains(convert(location, to: page)) }) { return self }
        }
        if let event = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown].contains(event.type) {
            let location = convert(point, from: superview)
            if let page = page(for: location, nearest: false) {
                let pagePoint = convert(location, to: page)
                if !PDFImageDrag.hasText(at: pagePoint, on: page), PDFContentRegions.imageBounds(at: pagePoint, on: page) != nil { return self }
            }
        }
        return target
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if drawingTool != nil { addCursorRect(bounds, cursor: .crosshair) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if drawingTool == nil, let editNote {
            let location = convert(event.locationInWindow, from: nil)
            if let page = page(for: location, nearest: false),
               let note = page.annotations.last(where: { $0.type == "Text" && $0.bounds.contains(convert(location, to: page)) }) {
                editNote(note)
                return
            }
        }
        if drawingTool == nil, imageDrag.prepare(at: convert(event.locationInWindow, from: nil)) {
            clearSelection(); window?.makeFirstResponder(self); return
        }
        guard drawingTool != nil else { super.mouseDown(with: event); return }
        cancelDrawing()
        guard beginDrawing?() ?? true else { return }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        guard let page = page(for: location, nearest: false), page.document === document else { return }
        let point = convert(location, to: page)
        guard page.bounds(for: .cropBox).contains(point) else { return }
        drawingPage = page; drawingPoints = [point]
        let path = CGMutablePath(); path.move(to: location); previewPath = path
    }
    override func mouseDragged(with event: NSEvent) {
        if drawingTool == nil, imageDrag.drag(with: event) { return }
        guard let tool = drawingTool else { super.mouseDragged(with: event); return }
        guard let page = drawingPage, page.document === document, drawingPoints.count < 10_000 else { return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        let crop = page.bounds(for: .cropBox)
        guard crop.contains(point) else { return }
        if let previous = drawingPoints.last, hypot(previous.x - point.x, previous.y - point.y) < 0.5 { return }
        drawingPoints.append(point)
        // Preview a vector path. Never rebuild PDF annotation appearances on pointer movement.
        if previewLayer == nil {
            wantsLayer = true
            let preview = CAShapeLayer(); preview.zPosition = 1000; preview.frame = bounds
            preview.fillColor = nil; preview.strokeColor = drawingColor.cgColor
            preview.lineWidth = 2 * scaleFactor; preview.lineCap = .round; preview.lineJoin = .round
            preview.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(preview); previewLayer = preview
        }
        let location = convert(point, from: page)
        if tool == .ink { previewPath?.addLine(to: location) }
        else {
            let first = convert(drawingPoints[0], from: page)
            let rect = CGRect(x: min(first.x, location.x), y: min(first.y, location.y), width: abs(location.x - first.x), height: abs(location.y - first.y))
            let path = CGMutablePath()
            if tool == .rectangle { path.addRect(rect) } else { path.addEllipse(in: rect) }
            previewPath = path
        }
        previewLayer?.path = previewPath
    }
    override func mouseUp(with event: NSEvent) {
        if imageDrag.isPending { imageDrag.cancel(); return }
        guard let tool = drawingTool else { super.mouseUp(with: event); return }
        let page = drawingPage, points = drawingPoints
        cancelDrawing()
        guard let page, page.document === document, let annotation = tool.annotation(points: points, on: page, color: drawingColor) else { return }
        commitDrawing?(page, annotation)
    }
    override func scrollWheel(with event: NSEvent) {
        imageDrag.cancel()
        if drawingPage != nil { cancelDrawing() }
        super.scrollWheel(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if imageDrag.isPending, event.keyCode == 53 { imageDrag.cancel(); return }
        if drawingTool != nil, event.keyCode == 53 { cancelDrawing(); finishDrawing?(); return }
        super.keyDown(with: event)
    }
    override func prepareForKeyboardPageChange() { cancelDrawing(); imageDrag.cancel() }
    func cancelDrawing() {
        previewLayer?.removeFromSuperlayer(); previewLayer = nil; previewPath = nil
        drawingPage = nil; drawingPoints = []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelDrawing(); imageDrag.cancel()
        let location = convert(event.locationInWindow, from: nil)
        let targetPage = page(for: location, nearest: false)
        let target = targetPage.flatMap { page in page.annotations.last { ["Text", "FreeText", "Highlight", "Underline", "Squiggly", "StrikeOut", "Ink", "Square", "Circle"].contains($0.type ?? "") && $0.bounds.contains(convert(location, to: page)) } }
        let selectedArea = targetPage.flatMap { page -> CGRect? in
            guard let selection = currentSelection, selection.pages.contains(where: { $0 === page }) else { return nil }
            let rect = selection.bounds(for: page)
            return PDFContentRegions.valid(rect) && rect.contains(convert(location, to: page)) ? rect : nil
        }
        let imageBounds = targetPage.flatMap { PDFContentRegions.imageBounds(at: convert(location, to: $0), on: $0) }
        let imageHit = imageBounds != nil
        if imageHit, let page = targetPage, currentSelection?.bounds(for: page).contains(convert(location, to: page)) != true { clearSelection() }
        if !imageHit, PDFSelectionContext(selection: currentSelection, document: document) == nil {
            let point = convert(event.locationInWindow, from: nil)
            if let page = page(for: point, nearest: false), page.document === document,
               let word = page.selectionForWord(at: convert(point, to: page)) {
                setCurrentSelection(word, animate: false)
            }
        }
        let menu = selectionMenu(for: currentSelection)
        if let targetPage { contentMenu.insert(in: menu, page: targetPage, imageBounds: imageBounds, point: convert(location, to: targetPage), selection: selectedArea) }
        if let target, let document, selectionActions.removeHighlight != nil || selectionActions.removeNote != nil {
            let command = HighlightRemovalCommand(view: self, document: document, annotation: target)
            let item = NSMenuItem(title: ["Text", "FreeText"].contains(target.type ?? "") ? "Delete Note" : ["Ink", "Square", "Circle"].contains(target.type ?? "") ? "Delete Drawing" : "Delete Highlight", action: #selector(HighlightRemovalCommand.invoke(_:)), keyEquivalent: "")
            item.target = command; item.representedObject = command; item.isEnabled = command.isEnabled
            menu.insertItem(.separator(), at: 0); menu.insertItem(item, at: 0)
        }
        return menu
    }

    func selectionMenu(for selection: PDFSelection?) -> NSMenu {
        let context = PDFSelectionContext(selection: selection, document: document)
        let menu = NSMenu(title: "Selection"); menu.autoenablesItems = false
        menu.addItem(item("Copy", action: .copy, context: context))
        menu.addItem(.separator())
        let highlight = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
        let colours = NSMenu(title: "Highlight"); colours.autoenablesItems = false
        for colour in HighlightColor.allCases {
            let option = item(colour.name, action: .highlight(colour), context: context)
            option.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                colour.color.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill(); return true
            }
            option.image?.isTemplate = false
            colours.addItem(option)
        }
        highlight.submenu = colours; highlight.isEnabled = colours.items.contains { $0.isEnabled }
        menu.addItem(highlight)
        menu.addItem(item("Add Note…", action: .note, context: context))
        menu.addItem(.separator())
        menu.addItem(item("Ask about Selection (on-device)", action: .ask, context: context))
        menu.addItem(item("Translate Selection…", action: .translate, context: context))
        return menu
    }

    private func item(_ title: String, action: SelectionCommand.Action, context: PDFSelectionContext?) -> NSMenuItem {
        let command = SelectionCommand(view: self, context: context, action: action)
        let item = NSMenuItem(title: title, action: #selector(SelectionCommand.invoke(_:)), keyEquivalent: "")
        item.target = command
        // NSMenuItem.target is weak. Ownership belongs to the menu item, not a process-wide registry.
        item.representedObject = command; item.isEnabled = command.isEnabled
        return item
    }
}

@MainActor
private final class HighlightRemovalCommand: NSObject {
    weak var view: PDFSelectionView?
    let document: PDFDocument
    let annotation: PDFAnnotation
    init(view: PDFSelectionView, document: PDFDocument, annotation: PDFAnnotation) { self.view = view; self.document = document; self.annotation = annotation }
    private var isNote: Bool { ["Text", "FreeText"].contains(annotation.type ?? "") }
    var isEnabled: Bool { view?.document === document && annotation.page?.document === document && !document.isLocked && !document.isEncrypted && document.allowsCommenting && (isNote ? view?.selectionActions.removeNote != nil : view?.selectionActions.removeHighlight != nil) }
    @objc func invoke(_ sender: NSMenuItem) {
        guard isEnabled else { return }
        if isNote { view?.selectionActions.removeNote?(document, annotation) }
        else { view?.selectionActions.removeHighlight?(document, annotation) }
    }
}

@MainActor
private final class SelectionCommand: NSObject {
    enum Action { case copy, highlight(HighlightColor), note, ask, translate }
    weak var view: PDFSelectionView?
    let context: PDFSelectionContext?
    let action: Action
    init(view: PDFSelectionView, context: PDFSelectionContext?, action: Action) {
        self.view = view; self.context = context; self.action = action
    }
    var isEnabled: Bool {
        guard let view, let context, context.isValid(in: view), context.document.allowsCopying else { return false }
        switch action {
        case .copy: return true
        case .ask: return view.selectionActions.ask != nil
        case .translate: return view.selectionActions.translate != nil
        case .highlight, .note:
            guard !context.document.isEncrypted, context.document.allowsCommenting,
                  view.selectionActions.canAnnotate?(context) ?? true else { return false }
            if case .note = action { return view.selectionActions.addNote != nil }
            return view.selectionActions.highlight != nil
        }
    }
    @objc func invoke(_ sender: NSMenuItem) {
        // Recheck identity and permissions even if the menu was enabled before a document changed.
        guard isEnabled, let view, let context else { return }
        switch action {
        case .copy:
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(context.selection.string ?? context.text, forType: .string)
        case .highlight(let colour): view.selectionActions.highlight?(context, colour)
        case .note: view.selectionActions.addNote?(context)
        case .ask: view.selectionActions.ask?(context)
        case .translate: view.selectionActions.translate?(context)
        }
    }
}
