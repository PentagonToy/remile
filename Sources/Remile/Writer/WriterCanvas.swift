import SwiftUI
import AppKit
import PDFKit

struct WriterSurface: NSViewRepresentable {
    @ObservedObject var model: WriterModel
    func makeNSView(context: Context) -> WriterDesk { WriterDesk(model: model) }
    func updateNSView(_ desk: WriterDesk, context: Context) { desk.update() }
    static func dismantleNSView(_ desk: WriterDesk, coordinator: ()) { desk.suspend() }

}

@MainActor final class WriterCanvas: NSView, NSTextViewDelegate {
    let model: WriterModel
    private(set) var sheets: [WriterPaper] = []
    private var shapeViews: [UUID: WriterShapeView] = [:]
    private var scheduled = false
    private var exclusions: [[CGRect]] = []
    private var configuredSize = CGSize.zero
    private var configuredColumns = 0
    var exporting = false
    override var isFlipped: Bool { true }
    var currentPage: Int { sheets.firstIndex(where: { $0.frame.intersects(visibleRect) }) ?? 0 }
    init(model: WriterModel) { self.model = model; super.init(frame: .zero); wantsLayer = true; registerForDraggedTypes([.fileURL, .png, .tiff]) }
    required init?(coder: NSCoder) { nil }
    func rebuild() {
        let range = model.activeText?.selectedRange()
        let focused = model.activeText != nil && window?.firstResponder === model.activeText
        suspend(); configuredSize = .zero; configuredColumns = 0; paginate()
        if let range, range.location <= model.storage.length {
            let caret = min(range.location, max(0, model.storage.length - 1))
            let view = sheets.flatMap(\.texts).first { text in
                guard let container = text.textContainer else { return false }
                return NSLocationInRange(caret, model.layout.characterRange(forGlyphRange: model.layout.glyphRange(for: container), actualGlyphRange: nil))
            } ?? sheets.first?.text
            model.activeText = view
            view?.setSelectedRange(NSRange(location: range.location, length: min(range.length, model.storage.length - range.location)))
            if focused, let view { window?.makeFirstResponder(view) }
        }
    }
    func suspend() {
        model.activeText = nil
        for sheet in sheets { sheet.texts.forEach { $0.delegate = nil }; sheet.removeFromSuperview() }
        while !model.layout.textContainers.isEmpty { model.layout.removeTextContainer(at: model.layout.textContainers.count - 1) }; sheets.removeAll(); shapeViews.removeAll(); exclusions = []
        if model.canvas === self { model.canvas = nil }
    }
    func synchronise(reflow: Bool = true) {
        if model.pageSize != configuredSize || configuredColumns != model.pageStyle.columnCount || sheets.isEmpty { paginate() }
        if reflow, syncExclusions() { paginate() }
        syncShapes(); needsDisplay = true
        sheets.forEach { $0.needsDisplay = true }
    }
    private func columnFrames() -> [CGRect] {
        let size = model.pageSize, count = model.pageStyle.columnCount
        let width = (size.width - 112 - Double(count - 1) * 20) / Double(count)
        return (0..<count).map { CGRect(x: 56 + Double($0) * (width + 20), y: 56, width: width, height: size.height - 112) }
    }
    private func makeText(_ frame: CGRect) -> WriterBodyText {
        let container = NSTextContainer(containerSize: frame.size)
        container.lineFragmentPadding = 0; container.widthTracksTextView = false; container.heightTracksTextView = false
        model.layout.addTextContainer(container)
        let text = WriterBodyText(frame: frame, textContainer: container)
        text.model = model; text.delegate = self; text.isRichText = true; text.allowsUndo = true; text.importsGraphics = false
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.backgroundColor = .white; text.textColor = .black; text.insertionPointColor = .black
        text.textContainerInset = .zero; text.isVerticallyResizable = false; text.isHorizontallyResizable = false
        text.typingAttributes = model.attributes
        return text
    }
    private func addSheet() {
        let texts = columnFrames().map { makeText($0) }
        let paper = WriterPaper(frame: CGRect(origin: .zero, size: model.pageSize), texts: texts, model: model, number: sheets.count + 1)
        addSubview(paper); sheets.append(paper)
        if model.activeText == nil { model.activeText = texts.first }
    }
    func paginate() {
        if configuredColumns != 0, configuredColumns != model.pageStyle.columnCount { rebuild(); return }
        configuredColumns = model.pageStyle.columnCount
        model.canvas = self
        let size = model.pageSize
        if configuredSize != size {
            configuredSize = size
            for sheet in sheets {
                sheet.frame.size = size
                for (text, frame) in zip(sheet.texts, columnFrames()) { text.frame = frame; text.textContainer?.containerSize = frame.size }
            }
        }
        if sheets.isEmpty { addSheet() }
        _ = syncExclusions()
        let required = max(1, (model.objects.map(\.page).max() ?? 0) + 1)
        while let container = sheets.last?.texts.last?.textContainer, sheets.count < 40 {
            model.layout.ensureLayout(for: container)
            if NSMaxRange(model.layout.glyphRange(for: container)) >= model.layout.numberOfGlyphs && sheets.count >= required { break }
            addSheet(); _ = syncExclusions()
        }
        while sheets.count > required, let last = sheets.last, let container = last.text.textContainer, model.layout.glyphRange(for: container).length == 0 {
            if last.texts.contains(where: { model.activeText === $0 }) { model.activeText = sheets.first?.text }
            for text in last.texts.reversed() { text.delegate = nil; model.layout.removeTextContainer(at: model.layout.textContainers.count - 1) }
            last.removeFromSuperview(); sheets.removeLast()
        }
        if exclusions.count != sheets.count * configuredColumns { _ = syncExclusions() }
        let visibleWidth = enclosingScrollView?.documentVisibleRect.width ?? size.width + 64
        frame.size = CGSize(width: max(size.width + 64, visibleWidth), height: Double(sheets.count) * (size.height + 24) + 40)
        for (index, sheet) in sheets.enumerated() { sheet.frame.origin = CGPoint(x: max(32, (frame.width - size.width) / 2), y: 24 + Double(index) * (size.height + 24)) }
        syncShapes()
        let count = sheets.count
        if model.pages != count { DispatchQueue.main.async { [weak model] in model?.setPages(count) } }
        if let last = sheets.last?.texts.last?.textContainer, NSMaxRange(model.layout.glyphRange(for: last)) < model.layout.numberOfGlyphs { model.error = "Writer supports up to 40 pages. Shorten this document before exporting." }
    }
    @discardableResult private func syncExclusions() -> Bool {
        let next: [[CGRect]] = sheets.indices.flatMap { page in
            let objects = model.objects.filter { $0.page == page && $0.wrapsText == true }
            return sheets[page].texts.map { text in
                let body = CGRect(origin: .zero, size: text.bounds.size)
                return objects.map { object in
                    var rect = object.bounds.insetBy(dx: -8, dy: -8).offsetBy(dx: -text.frame.minX, dy: -text.frame.minY).intersection(body)
                    guard !rect.isNull && !rect.isEmpty else { return rect }
                    // Avoid word-sized columns between an object and the page margin.
                    if rect.minX < 72 { rect.size.width += rect.minX; rect.origin.x = 0 }
                    if body.maxX - rect.maxX < 72 { rect.size.width = body.maxX - rect.minX }
                    return rect
                }.filter { !$0.isNull && !$0.isEmpty }
            }
        }
        guard next != exclusions else { return false }
        exclusions = next
        for (text, paths) in zip(sheets.flatMap(\.texts), next) { text.textContainer?.exclusionPaths = paths.map { NSBezierPath(rect: $0) } }
        return true
    }
    func baselines(on page: Int) -> [CGFloat] {
        guard sheets.indices.contains(page) else { return [] }
        var values: [CGFloat] = []
        for text in sheets[page].texts {
            guard values.count < 256, let container = text.textContainer else { break }
            model.layout.enumerateLineFragments(forGlyphRange: model.layout.glyphRange(for: container)) { rect, _, _, range, stop in
                if range.length > 0 { values.append(text.frame.minY + rect.minY + self.model.layout.location(forGlyphAt: range.location).y) }
                if values.count >= 256 { stop.pointee = true }
            }
        }
        return values
    }
    func showGuides(_ guides: [WriterGuide], page: Int) {
        for (index, sheet) in sheets.enumerated() { sheet.guides = index == page ? guides : []; sheet.needsDisplay = true }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let width = enclosingScrollView?.documentVisibleRect.width ?? newSize.width
        super.setFrameSize(CGSize(width: max(model.pageSize.width + 64, width), height: newSize.height))
        for sheet in sheets { sheet.frame.origin.x = max(32, (frame.width - model.pageSize.width) / 2) }
    }
    func fitViewport() { setFrameSize(frame.size) }
    private func syncShapes() {
        let ids = Set(model.objects.map(\.id))
        for id in shapeViews.keys.filter({ !ids.contains($0) }) { shapeViews.removeValue(forKey: id)?.removeFromSuperview() }
        for object in model.objects where object.page < sheets.count {
            let view = shapeViews[object.id] ?? WriterShapeView(model: model, id: object.id)
            if view.superview !== sheets[object.page] { view.removeFromSuperview(); sheets[object.page].addSubview(view) }
            shapeViews[object.id] = view; view.frame = object.bounds.insetBy(dx: -12, dy: -12); view.needsDisplay = true
        }
    }
    func textDidBeginEditing(_ notification: Notification) { if let view = notification.object as? NSTextView { model.activeText = view; model.choose(nil) } }
    func textViewDidChangeSelection(_ notification: Notification) { if let view = notification.object as? NSTextView { model.activeText = view; model.reflectStyle(view) } }
    func textDidChange(_ notification: Notification) {
        model.choose(nil); model.changed()
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in self?.scheduled = false; self?.paginate() }
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let count = model.storage.length - affectedCharRange.length + ((replacementString as NSString?)?.length ?? 0)
        guard count <= 200_000 else { model.error = "Writer supports up to 200,000 characters."; return false }; return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let position = convert(sender.draggingLocation, from: nil)
        let page = sheets.firstIndex { $0.frame.contains(position) } ?? currentPage
        let point = CGPoint(x: position.x - sheets[page].frame.minX, y: position.y - sheets[page].frame.minY)
        return model.pasteImage(sender.draggingPasteboard, at: point, page: page)
    }
    func ranges() -> [NSRange] {
        paginate()
        return sheets.map { sheet in
            let ranges = sheet.texts.compactMap(\.textContainer).map { model.layout.characterRange(forGlyphRange: model.layout.glyphRange(for: $0), actualGlyphRange: nil) }
            let start = ranges.first?.location ?? 0, end = ranges.last.map(NSMaxRange) ?? start
            return NSRange(location: start, length: max(0, end - start))
        }
    }
    func pdf() throws -> Data {
        paginate()
        guard let container = sheets.last?.texts.last?.textContainer, NSMaxRange(model.layout.glyphRange(for: container)) >= model.layout.numberOfGlyphs else { throw ReferenceFailure("Shorten this document before exporting.") }
        exporting = true; defer { exporting = false; shapeViews.values.forEach { $0.needsDisplay = true } }
        shapeViews.values.forEach { $0.needsDisplay = true }
        let document = PDFDocument()
        for sheet in sheets {
            sheet.displayIfNeeded()
            guard let page = PDFDocument(data: sheet.dataWithPDF(inside: sheet.bounds))?.page(at: 0) else { throw ReferenceFailure("Could not create the PDF.") }
            document.insert(page, at: document.pageCount)
        }
        guard let data = document.dataRepresentation() else { throw ReferenceFailure("Could not create the PDF.") }; return data
    }
}


@MainActor final class WriterBodyText: NSTextView {
    weak var model: WriterModel?
    private var ownsEditGroup = false
    private func beginEditGroup() {
        if let undo = model?.undo, undo.groupingLevel == 0 { undo.beginUndoGrouping(); ownsEditGroup = true }
    }
    private func endEditGroup() {
        if ownsEditGroup { ownsEditGroup = false; model?.undo.endUndoGrouping() }
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        beginEditGroup()
        let result = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if !result { endEditGroup() }; return result
    }
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        beginEditGroup()
        let result = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if !result { endEditGroup() }; return result
    }
    override func insertNewline(_ sender: Any?) {
        if model?.insertListNewline(in: self) != true { super.insertNewline(sender) }
    }
    override func didChangeText() { super.didChangeText(); endEditGroup() }
    override var undoManager: UndoManager? { model?.undo ?? super.undoManager }
    override func paste(_ sender: Any?) { if model?.pasteImage(.general) != true { pasteAsPlainText(sender) } }
    override func becomeFirstResponder() -> Bool { model?.activeText = self; model?.choose(nil); return super.becomeFirstResponder() }
}

@MainActor final class WriterPaper: NSView {
    let texts: [WriterBodyText]
    var text: WriterBodyText { texts[0] }
    private weak var model: WriterModel?
    private let number: Int
    private let overlay = WriterGuideOverlay()
    var guides: [WriterGuide] = [] {
        didSet { overlay.guides = guides; overlay.needsDisplay = true; overlay.frame = bounds; addSubview(overlay, positioned: .above, relativeTo: nil) }
    }
    override var isFlipped: Bool { true }
    init(frame: CGRect, texts: [WriterBodyText], model: WriterModel, number: Int) {
        self.texts = texts; self.model = model; self.number = number
        super.init(frame: frame); overlay.model = model; wantsLayer = true; layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderWidth = 0.5; layer?.borderColor = NSColor.gray.withAlphaComponent(0.25).cgColor; texts.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let style = model.pageStyle
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman", size: 10) ?? NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
        (style.header as NSString).draw(in: CGRect(x: 56, y: 22, width: bounds.width - 112, height: 16), withAttributes: attrs)
        let footer = style.footer + (style.pageNumbers ? (style.footer.isEmpty ? "" : " · ") + String(number) : "")
        (footer as NSString).draw(in: CGRect(x: 56, y: bounds.height - 34, width: bounds.width - 112, height: 16), withAttributes: attrs)
        let rules = NSBezierPath(); rules.lineWidth = 0.5
        if style.topLine { rules.move(to: CGPoint(x: 56, y: 42)); rules.line(to: CGPoint(x: bounds.width - 56, y: 42)) }
        if style.bottomLine { rules.move(to: CGPoint(x: 56, y: bounds.height - 42)); rules.line(to: CGPoint(x: bounds.width - 56, y: bounds.height - 42)) }
        NSColor.black.setStroke(); rules.stroke()

    }
}

@MainActor private final class WriterGuideOverlay: NSView {
    weak var model: WriterModel?
    var guides: [WriterGuide] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard model?.canvas?.exporting != true else { return }
        let path = NSBezierPath(); path.lineWidth = 0.6; path.setLineDash([3, 3], count: 2, phase: 0)
        for guide in guides {
            path.move(to: guide.axis == .x ? CGPoint(x: guide.position, y: 12) : CGPoint(x: 12, y: guide.position))
            path.line(to: guide.axis == .x ? CGPoint(x: guide.position, y: bounds.height - 12) : CGPoint(x: bounds.width - 12, y: guide.position))
        }
        NSColor(RemileStyle.accent).setStroke(); path.stroke()
    }
}

@MainActor final class WriterShapeView: NSView, NSTextViewDelegate {
    weak var model: WriterModel?
    let id: UUID
    private var cachedImage: NSImage?
    private var editor: WriterBoxText?
    private var editingCell: Int?
    private var original: [WriterObject] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { model?.undo }
    var object: WriterObject? { model?.objects.first { $0.id == id } }
    init(model: WriterModel, id: UUID) { self.model = model; self.id = id; super.init(frame: .zero); setAccessibilityLabel("Writer shape"); setAccessibilityRole(.button) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let object, object.kind == .line {
            let p = convert(point, from: superview), a = CGPoint(x: object.start.x - frame.minX, y: object.start.y - frame.minY), b = CGPoint(x: object.end.x - frame.minX, y: object.end.y - frame.minY)
            let dx = b.x - a.x, dy = b.y - a.y, t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(1, dx * dx + dy * dy)))
            if hypot(p.x - a.x - t * dx, p.y - a.y - t * dy) > 12 { return nil }
        }
        return super.hitTest(point)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let object else { return }
        let offset = frame.origin, a = CGPoint(x: object.start.x - offset.x, y: object.start.y - offset.y), b = CGPoint(x: object.end.x - offset.x, y: object.end.y - offset.y)
        let colour = WriterPalette.colour(object.hex); colour.setStroke()
        let path = NSBezierPath(); path.lineWidth = object.width
        if object.kind == .line {
            path.move(to: a); path.line(to: b); path.stroke()
            arrow(at: a, from: b, style: object.startArrow, colour: colour, width: object.width)
            arrow(at: b, from: a, style: object.endArrow, colour: colour, width: object.width)
        } else if object.kind == .image {
            if cachedImage == nil, let data = object.imageData { cachedImage = NSImage(data: data) }
            cachedImage?.draw(in: bounds.insetBy(dx: 12, dy: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if object.kind == .table {
            let rect = bounds.insetBy(dx: 12, dy: 12), grid = NSBezierPath(); grid.lineWidth = object.width
            for column in 0...object.columns { let x = rect.minX + rect.width * Double(column) / Double(object.columns); grid.move(to: CGPoint(x: x, y: rect.minY)); grid.line(to: CGPoint(x: x, y: rect.maxY)) }
            for row in 0...object.rows { let y = rect.minY + rect.height * Double(row) / Double(object.rows); grid.move(to: CGPoint(x: rect.minX, y: y)); grid.line(to: CGPoint(x: rect.maxX, y: y)) }
            grid.stroke()
            let style = NSMutableParagraphStyle(); style.alignment = NSTextAlignment(rawValue: object.alignment) ?? .left
            for index in object.cells.indices where index != editingCell {
                let cell = cellFrame(object, index: index).insetBy(dx: 5, dy: 4)
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: cell).addClip()
                (object.cells[index] as NSString).draw(in: cell, withAttributes: [.font: object.textFont, .foregroundColor: colour, .paragraphStyle: style])
                NSGraphicsContext.restoreGraphicsState()
            }
        } else {
            let rect = bounds.insetBy(dx: 12, dy: 12), box = NSBezierPath(rect: rect); box.lineWidth = object.width
            if object.filled { WriterPalette.colour(object.fillHex ?? object.hex).withAlphaComponent(object.fillOpacity ?? 0.12).setFill(); box.fill() }; box.stroke()
            if editor == nil {
                let style = NSMutableParagraphStyle(); style.alignment = NSTextAlignment(rawValue: object.alignment) ?? .left
                (object.text as NSString).draw(in: rect.insetBy(dx: 8, dy: 6), withAttributes: [.font: object.textFont, .foregroundColor: colour, .paragraphStyle: style])
            }
        }
        if model?.selected == id && model?.canvas?.exporting != true {
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 7, dy: 7)).stroke()
            for point in [a, b] { NSColor.white.setFill(); let circle = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)); circle.fill(); NSColor.controlAccentColor.setStroke(); circle.stroke() }
        }
    }
    private func arrow(at tip: CGPoint, from other: CGPoint, style: WriterObject.Arrow, colour: NSColor, width: Double) {
        guard style != .none else { return }
        let angle = atan2(tip.y - other.y, tip.x - other.x), size = max(9, width * 5)
        let path = NSBezierPath(); path.move(to: CGPoint(x: tip.x - size * cos(angle - 0.45), y: tip.y - size * sin(angle - 0.45))); path.line(to: tip); path.line(to: CGPoint(x: tip.x - size * cos(angle + 0.45), y: tip.y - size * sin(angle + 0.45))); path.lineWidth = width
        colour.setStroke(); if style == .filled { path.close(); colour.setFill(); path.fill() } else { path.stroke() }
    }
    override func mouseDown(with event: NSEvent) {
        guard let model, let object, let page = superview else { return }
        model.choose(object); window?.makeFirstResponder(self)
        if event.clickCount == 2, (object.kind == .rectangle || object.kind == .table) {
            if object.kind == .table {
                let point = convert(event.locationInWindow, from: nil), rect = bounds.insetBy(dx: 12, dy: 12)
                let column = min(object.columns - 1, max(0, Int((point.x - rect.minX) / max(1, rect.width) * Double(object.columns))))
                let row = min(object.rows - 1, max(0, Int((point.y - rect.minY) / max(1, rect.height) * Double(object.rows))))
                editingCell = row * object.columns + column
            }
            beginText(object); return
        }
        guard object.locked != true else { return }
        let initial = page.convert(event.locationInWindow, from: nil), before = model.objects
        let neighbours = model.objects.filter { $0.id != object.id && $0.page == object.page }.map(\.bounds)
        let baselines = model.canvas?.baselines(on: object.page) ?? []
        let startHandle = hypot(initial.x - object.start.x, initial.y - object.start.y) < 12
        let endHandle = hypot(initial.x - object.end.x, initial.y - object.end.y) < 12
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = page.convert(next.locationInWindow, from: nil), delta = CGPoint(x: point.x - initial.x, y: point.y - initial.y)
            func moved(_ p: CGPoint) -> CGPoint { CGPoint(x: min(model.pageSize.width - 12, max(12, p.x + delta.x)), y: min(model.pageSize.height - 12, max(12, p.y + delta.y))) }
            var item = object
            if !endHandle { item.start = moved(object.start) }; if !startHandle { item.end = moved(object.end) }
            if object.kind == .image && (startHandle || endHandle) {
                let width = object.bounds.width, height = object.bounds.height
                if startHandle {
                    let scale = min(max(24 / width, (object.end.x - item.start.x) / width), max(0.05, (object.end.x - 12) / width), max(0.05, (object.end.y - 12) / height))
                    item.start = CGPoint(x: object.end.x - width * scale, y: object.end.y - height * scale)
                } else {
                    let scale = min(max(24 / width, (item.end.x - object.start.x) / width), max(0.05, (model.pageSize.width - object.start.x - 12) / width), max(0.05, (model.pageSize.height - object.start.y - 12) / height))
                    item.end = CGPoint(x: object.start.x + width * scale, y: object.start.y + height * scale)
                }
            }
            if startHandle || endHandle {
                if object.kind == .line, next.modifierFlags.contains(.shift) {
                    if startHandle { item.start = WriterAlignment.constrained(item.start, from: item.end) }
                    else { item.end = WriterAlignment.constrained(item.end, from: item.start) }
                }
            } else {
                var translation = delta
                let constrained = next.modifierFlags.contains(.shift)
                if constrained { translation = WriterAlignment.constrained(translation, from: .zero) }
                translation.x = min(model.pageSize.width - object.bounds.maxX - 12, max(12 - object.bounds.minX, translation.x))
                translation.y = min(model.pageSize.height - object.bounds.maxY - 12, max(12 - object.bounds.minY, translation.y))
                item.start = CGPoint(x: object.start.x + translation.x, y: object.start.y + translation.y)
                item.end = CGPoint(x: object.end.x + translation.x, y: object.end.y + translation.y)
                if !next.modifierFlags.contains(.option) {
                    var snap = WriterAlignment.snap(item.bounds, page: model.pageSize, neighbours: neighbours, baselines: baselines, tolerance: 5 / model.zoom)
                    if constrained {
                        if abs(delta.x) >= abs(delta.y) { snap.0.y = 0; snap.1.removeAll { $0.axis == .y } }
                        else { snap.0.x = 0; snap.1.removeAll { $0.axis == .x } }
                    }
                    model.canvas?.showGuides([], page: object.page)
                    let moved = item.bounds.offsetBy(dx: snap.0.x, dy: snap.0.y)
                    if moved.minX >= 12, moved.maxX <= model.pageSize.width - 12, moved.minY >= 12, moved.maxY <= model.pageSize.height - 12 {
                        item.start.x += snap.0.x; item.end.x += snap.0.x; item.start.y += snap.0.y; item.end.y += snap.0.y
                        model.canvas?.showGuides(snap.1, page: object.page)
                    }
                } else { model.canvas?.showGuides([], page: object.page) }
            }
            model.update(item, undoable: false)
        }
        model.canvas?.showGuides([], page: object.page)
        model.finishDrag(from: before)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 51 || event.keyCode == 117 { model?.deleteShape() } else if event.keyCode == 53 { model?.choose(nil) } else { super.keyDown(with: event) } }
    private func cellFrame(_ object: WriterObject, index: Int) -> CGRect {
        let rect = bounds.insetBy(dx: 12, dy: 12), width = rect.width / Double(object.columns), height = rect.height / Double(object.rows)
        return CGRect(x: rect.minX + Double(index % object.columns) * width, y: rect.minY + Double(index / object.columns) * height, width: width, height: height)
    }
    private func beginText(_ object: WriterObject) {
        guard editor == nil, let model else { return }; original = model.objects
        let frame = editingCell.map { cellFrame(object, index: $0).insetBy(dx: 5, dy: 4) } ?? bounds.insetBy(dx: 20, dy: 18)
        let view = WriterBoxText(frame: frame); view.string = editingCell.map { object.cells[$0] } ?? object.text; view.font = object.textFont
        view.textColor = WriterPalette.colour(object.hex); view.backgroundColor = .white; view.drawsBackground = false
        view.isRichText = false; view.allowsUndo = false; view.delegate = self; view.textContainerInset = .zero
        view.alignment = NSTextAlignment(rawValue: object.alignment) ?? .left
        if object.kind == .table {
            view.tab = { [weak self] backwards in
                guard let self, let cell = self.editingCell, let object = self.object else { return }
                let next = (cell + (backwards ? object.cells.count - 1 : 1)) % object.cells.count
                self.window?.makeFirstResponder(self)
                self.editingCell = next
                if let current = self.object { self.beginText(current) }
            }
        }
        view.finished = { [weak self] in self?.finishText() }; editor = view; addSubview(view); window?.makeFirstResponder(view)
    }
    func textDidChange(_ notification: Notification) { guard var item = object, let editor else { return }; if let cell = editingCell, item.cells.indices.contains(cell) { item.cells[cell] = String(editor.string.prefix(2_000)) } else { item.text = String(editor.string.prefix(10_000)) }; model?.update(item, undoable: false) }
    private func finishText() { guard let view = editor else { return }; editor = nil; editingCell = nil; view.finished = nil; view.removeFromSuperview(); model?.finishDrag(from: original); needsDisplay = true }
}

@MainActor final class WriterBoxText: NSTextView {
    var finished: (() -> Void)?
    var tab: ((Bool) -> Void)?
    override func insertTab(_ sender: Any?) { if let tab { tab(false) } else { super.insertTab(sender) } }
    override func insertBacktab(_ sender: Any?) { if let tab { tab(true) } else { super.insertBacktab(sender) } }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result { finished?() }; return result }
}
