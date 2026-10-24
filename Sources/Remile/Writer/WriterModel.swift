import AppKit
import Combine
import PDFKit
import UniformTypeIdentifiers

@MainActor final class WriterModel: NSObject, ObservableObject {
    let identity = UUID()
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let undo = UndoManager()
    @Published private(set) var revision = UUID()
    @Published private(set) var dirty = false
    @Published var selected: UUID?
    @Published var paper = PaperSize.a4.rawValue
    @Published var landscape = false
    @Published var font = WriterFont.times
    @Published var size = 12.0
    @Published var bold = false
    @Published var italic = false
    @Published var list = WriterList.none
    @Published var alignment = 0
    @Published var leading = 1.0
    @Published var zoom = 1.0
    @Published var showRulers = false
    @Published var palette = WriterPalette.okabeIto
    @Published var colour: UInt32 = 0x000000
    @Published var lineWidth = 1.5
    @Published var startArrow = WriterObject.Arrow.none
    @Published var endArrow = WriterObject.Arrow.none
    @Published var fill = false
    @Published var fillColour: UInt32 = 0xE69F00
    @Published var fillOpacity = 0.12
    @Published private(set) var pageStyle = WriterPageStyle()
    @Published var error: String?
    @Published var rendering = false
    @Published private(set) var loading = false
    @Published private(set) var pages = 1
    private(set) var objects: [WriterObject] = []
    private(set) var url: URL?
    weak var activeText: NSTextView?
    weak var canvas: WriterCanvas?
    var didVisit: ((URL) -> Void)?
    var textChanged: (() -> Void)?
    var pageSize: CGSize { (PaperSize(rawValue: paper) ?? .a4).points(landscape: landscape) }
    var title: String { url?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    var selectedObject: WriterObject? { objects.first { $0.id == selected } }
    var attributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle(); style.alignment = NSTextAlignment(rawValue: alignment) ?? .left; style.lineHeightMultiple = leading
        return [.font: WriterFont.styled(font.family, size: size, bold: bold, italic: italic), .foregroundColor: WriterPalette.colour(colour), .paragraphStyle: style.copy() as! NSParagraphStyle]
    }
    override init() { super.init(); undo.groupsByEvent = false; undo.levelsOfUndo = 30; storage.addLayoutManager(layout); layout.allowsNonContiguousLayout = false }
    private func recordUndo(name: String = "Edit", _ action: @escaping (WriterModel) -> Void) {
        let opensGroup = undo.groupingLevel == 0
        if opensGroup { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self, handler: action)
        undo.setActionName(name)
        if opensGroup { undo.endUndoGrouping() }
    }
    func revisionChanged() { revision = UUID(); canvas?.paginate() }
    func changed() { dirty = true; revision = UUID(); textChanged?() }
    func setPages(_ count: Int) { if pages != count { pages = count } }
    func choose(_ object: WriterObject?) {
        selected = object?.id
        if let object { bold = object.bold == true; italic = object.italic == true; font = WriterFont.allCases.first { $0.family == object.font } ?? .times; size = object.fontSize; alignment = object.alignment; colour = object.hex; lineWidth = object.width; fill = object.filled; fillColour = object.fillHex ?? object.hex; fillOpacity = object.fillOpacity ?? 0.12; startArrow = object.startArrow; endArrow = object.endArrow }
    }
    func add(_ kind: WriterObject.Kind) {
        guard objects.count < 100 else { error = "Use up to 100 shapes."; return }
        var item = WriterObject(kind: kind); item.page = canvas?.currentPage ?? 0
        item.bold = bold; item.italic = italic; item.font = font.family; item.fontSize = size; item.alignment = alignment
        item.hex = colour; item.width = lineWidth; item.filled = fill; item.fillHex = fillColour; item.fillOpacity = fillOpacity; item.startArrow = startArrow; item.endArrow = endArrow
        if kind == .line { item.end.y = item.start.y }
        if kind == .table { item.end = CGPoint(x: 420, y: 280) }
        item.start.y += Double(objects.filter { $0.page == item.page }.count % 8) * 22; item.end.y += Double(objects.filter { $0.page == item.page }.count % 8) * 22
        let before = objects; objects.append(item); registerObjects(before); choose(item); changed()
    }
    func insertObject(_ item: WriterObject) {
        let before = objects; objects.append(item); registerObjects(before); choose(item); changed()
    }
    func update(_ item: WriterObject, undoable: Bool = true) {
        guard let index = objects.firstIndex(where: { $0.id == item.id }), objects[index] != item else { return }
        let before = objects; objects[index] = item
        if undoable { registerObjects(before); changed() } else { if !dirty { dirty = true }; canvas?.synchronise(reflow: false) }
    }
    func finishDrag(from before: [WriterObject]) { if objects != before { registerObjects(before); changed(); canvas?.paginate() } }
    private func registerObjects(_ before: [WriterObject]) {
        recordUndo(name: "Object") { target in let after = target.objects; target.objects = before; target.registerObjects(after); target.changed() }
    }
    func resizeTable(rows: Int, columns: Int) {
        guard var object = selectedObject, object.kind == .table, (1...12).contains(rows), (1...12).contains(columns) else { return }
        var cells = Array(repeating: "", count: rows * columns)
        for row in 0..<min(rows, object.rows) { for column in 0..<min(columns, object.columns) { cells[row * columns + column] = object.cells[row * object.columns + column] } }
        object.rows = rows; object.columns = columns; object.cells = cells; update(object)
    }
    func deleteShape() { guard let selected else { return }; let before = objects; objects.removeAll { $0.id == selected }; registerObjects(before); self.selected = nil; changed() }
    func format() {
        if var object = selectedObject {
            object.hex = colour; object.width = lineWidth; object.startArrow = startArrow; object.endArrow = endArrow; object.filled = fill; object.fillHex = fillColour; object.fillOpacity = fillOpacity
            object.bold = bold; object.italic = italic; object.font = font.family; object.fontSize = size; object.alignment = alignment; update(object); return
        }
        guard let view = activeText else { return }
        var values = attributes
        if storage.length > 0, let existing = storage.attribute(.paragraphStyle, at: min(view.selectedRange().location, storage.length - 1), effectiveRange: nil) as? NSParagraphStyle {
            let style = existing.mutableCopy() as! NSMutableParagraphStyle
            style.alignment = NSTextAlignment(rawValue: alignment) ?? .left; style.lineHeightMultiple = leading
            values[.paragraphStyle] = style.copy() as! NSParagraphStyle
        }
        view.typingAttributes = values
        let range = view.selectedRange(), paragraph = (storage.string as NSString).paragraphRange(for: range)
        guard paragraph.length > 0 else { return }
        let before = storage.attributedSubstring(from: paragraph), after = NSMutableAttributedString(attributedString: before)
        if range.length > 0 { after.addAttributes([.font: values[.font]!, .foregroundColor: values[.foregroundColor]!], range: NSRange(location: range.location - paragraph.location, length: range.length)) }
        after.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: after.length)) { value, subrange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.alignment = NSTextAlignment(rawValue: alignment) ?? .left; style.lineHeightMultiple = leading
            after.addAttribute(.paragraphStyle, value: style.copy() as! NSParagraphStyle, range: subrange)
        }
        guard !before.isEqual(to: after) else { return }
        replaceRange(paragraph, with: after); canvas?.paginate()
    }
    private func replaceRange(_ range: NSRange, with text: NSAttributedString) {
        guard NSMaxRange(range) <= storage.length else { return }
        let before = storage.attributedSubstring(from: range)
        recordUndo { $0.replaceRange(NSRange(location: range.location, length: text.length), with: before) }
        storage.replaceCharacters(in: range, with: text); changed()
    }
    func reflectStyle(_ view: NSTextView) {
        guard selected == nil else { return }
        let attributes = view.typingAttributes
        if let value = attributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: value)
            bold = traits.contains(.boldFontMask); italic = traits.contains(.italicFontMask)
            font = WriterFont.allCases.first { $0.family == value.familyName } ?? .times; size = value.pointSize
        }
        if let value = attributes[.foregroundColor] as? NSColor { colour = WriterPalette.hex(value) }
        if let value = attributes[.paragraphStyle] as? NSParagraphStyle { list = WriterList.allCases.first { $0.format == value.textLists.first?.markerFormat } ?? .none; alignment = value.alignment.rawValue; leading = value.lineHeightMultiple > 0 ? value.lineHeightMultiple : 1.0 }
    }
    func bullet() { applyList(list == .bullet ? .none : .bullet) }
    func applyList(_ choice: WriterList) {
        guard let view = activeText, selectedObject == nil else { return }
        let range = (storage.string as NSString).paragraphRange(for: view.selectedRange())
        let result = NSMutableAttributedString(string: "")
        let source = storage.string as NSString
        var location = range.location, number = 1
        let newList = choice.format.map { NSTextList(markerFormat: $0, options: 0) }
        while location < NSMaxRange(range) {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraph))
            let style = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            if let old = style.textLists.first {
                // Strip only a marker belonging to an actual list paragraph.
                let line = text.string as NSString
                if let tab = text.string.firstIndex(of: "\t"), text.string.distance(from: text.string.startIndex, to: tab) < 20 {
                    let length = (String(text.string[...tab]) as NSString).length
                    if line.length >= length { text.deleteCharacters(in: NSRange(location: 0, length: length)) }
                } else if old.markerFormat == .disc && text.string.hasPrefix("• ") { text.deleteCharacters(in: NSRange(location: 0, length: 2)) }
            } else if text.string.hasPrefix("• ") { text.deleteCharacters(in: NSRange(location: 0, length: 2)) }
            style.textLists = newList.map { [$0] } ?? []
            style.firstLineHeadIndent = 0; style.headIndent = newList == nil ? 0 : 24
            if let newList {
                let attrs = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : attributes
                text.insert(NSAttributedString(string: WriterList.marker(newList, number: number), attributes: attrs), at: 0)
            }
            if text.length > 0 { text.addAttribute(.paragraphStyle, value: style.copy() as! NSParagraphStyle, range: NSRange(location: 0, length: text.length)) }
            result.append(text); location = NSMaxRange(paragraph); number += 1
        }
        if range.length == 0 {
            let style = NSMutableParagraphStyle(); style.textLists = newList.map { [$0] } ?? []; style.headIndent = newList == nil ? 0 : 24
            var attrs = attributes; attrs[.paragraphStyle] = style.copy() as! NSParagraphStyle
            if let newList { result.append(NSAttributedString(string: WriterList.marker(newList, number: 1), attributes: attrs)) }
            view.typingAttributes = attrs
        }
        replaceRange(range, with: result)
        view.setSelectedRange(NSRange(location: range.location, length: result.length))
        list = choice; canvas?.paginate()
    }
    func insertListNewline(in view: NSTextView) -> Bool {
        let caret = view.selectedRange()
        guard caret.length == 0, storage.length > 0, caret.location <= storage.length else { return false }
        let source = storage.string as NSString
        let paragraph = source.paragraphRange(for: caret)
        guard paragraph.length > 0, let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
              let current = style.textLists.first else { return false }
        let line = source.substring(with: paragraph)
        guard let tab = line.firstIndex(of: "\t") else { return false }
        let prefix = (String(line[...tab]) as NSString).length
        var attrs = storage.attributes(at: min(caret.location, storage.length - 1), effectiveRange: nil)
        if line.dropFirst(prefix).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let plain = style.mutableCopy() as! NSMutableParagraphStyle
            plain.textLists = []; plain.headIndent = 0; plain.firstLineHeadIndent = 0
            attrs[.paragraphStyle] = plain.copy() as! NSParagraphStyle
            view.insertText(NSAttributedString(string: "", attributes: attrs), replacementRange: NSRange(location: paragraph.location, length: prefix))
            view.typingAttributes = attrs; list = .none
        } else {
            var number = 2, previous = paragraph.location
            while previous > 0 {
                let before = source.paragraphRange(for: NSRange(location: previous - 1, length: 0))
                let previousStyle = storage.attribute(.paragraphStyle, at: before.location, effectiveRange: nil) as? NSParagraphStyle
                guard previousStyle?.textLists.first === current else { break }
                number += 1; previous = before.location
            }
            attrs[.paragraphStyle] = style
            view.insertText(NSAttributedString(string: "\n" + WriterList.marker(current, number: number), attributes: attrs), replacementRange: caret)
            view.typingAttributes = attrs
        }
        return true
    }
    func insertFormula(_ source: String) async {
        guard !rendering, source.utf8.count <= 10_000 else { return }
        var count = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if value != nil { count += 1 } }
        guard count < 100 else { error = "Use up to 100 equations."; return }
        rendering = true; defer { rendering = false }
        do {
            let markup = try MathMarkup.render(source, display: false)
            let image = try await WordArt.image(markup)
            let columnWidth = (pageSize.width - 112 - Double(pageStyle.columnCount - 1) * 20) / Double(pageStyle.columnCount)
            let scale = min(size / 12, columnWidth / image.size.width, (pageSize.height - 112) / image.size.height)
            image.size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            guard let view = activeText else { throw ReferenceFailure("Click in the document first.") }
            let attachment = NSTextAttachment(); attachment.image = image; attachment.bounds = CGRect(origin: CGPoint(x: 0, y: -3), size: image.size)
            let string = NSMutableAttributedString(attachment: attachment)
            string.addAttributes([.init("remile.formula"): source], range: NSRange(location: 0, length: string.length))
            view.insertText(string, replacementRange: view.selectedRange())
        } catch { self.error = error.localizedDescription }
    }
    func setPageStyle(_ style: WriterPageStyle) {
        guard style.valid, style != pageStyle else { return }
        let before = pageStyle
        recordUndo(name: "Page") { $0.setPageStyle(before) }
        pageStyle = style
        if before.columnCount != style.columnCount { fitInlineImages() }
        changed(); canvas?.synchronise()
    }
    private func fitInlineImages() {
        let width = (pageSize.width - 112 - Double(pageStyle.columnCount - 1) * 20) / Double(pageStyle.columnCount)
        var replacements: [(NSRange, NSTextAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let original = value as? NSTextAttachment, let image = original.image ?? (original.attachmentCell as? NSTextAttachmentCell)?.image, image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(1, width / image.size.width, (pageSize.height - 112) / image.size.height)
            let replacement = NSTextAttachment(); replacement.image = image
            replacement.bounds = CGRect(origin: original.bounds.origin, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            replacements.append((range, replacement))
        }
        for (range, replacement) in replacements { storage.addAttribute(.attachment, value: replacement, range: range) }
    }
    func setZoom(_ value: Double) {
        guard value.isFinite else { return }
        zoom = min(2, max(0.25, value))
    }
    func fitWidth() {
        guard let scroll = canvas?.enclosingScrollView else { return }
        setZoom((scroll.contentSize.width - 64) / pageSize.width)
    }
    func resizePaper(_ name: String, landscape: Bool) {
        guard PaperSize(rawValue: name) != nil, name != paper || landscape != self.landscape else { return }
        let before = (paper, self.landscape)
        recordUndo { $0.resizePaper(before.0, landscape: before.1) }
        let oldSize = pageSize
        paper = name; self.landscape = landscape
        let newSize = pageSize
        for index in objects.indices {
            objects[index].start = CGPoint(x: objects[index].start.x * newSize.width / oldSize.width, y: objects[index].start.y * newSize.height / oldSize.height)
            objects[index].end = CGPoint(x: objects[index].end.x * newSize.width / oldSize.width, y: objects[index].end.y * newSize.height / oldSize.height)
        }
        fitInlineImages(); changed(); canvas?.paginate()
    }
    @discardableResult func save(to destination: URL? = nil) -> Bool {
        canvas?.window?.makeFirstResponder(nil)
        let destination = destination ?? url ?? chooseDestination(pdf: false)
        guard let destination else { return false }
        do { let data = try data(for: destination); try data.write(to: destination, options: .atomic); url = destination; dirty = false; revision = UUID(); didVisit?(destination); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func chooseDestination(pdf: Bool) -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = title + (pdf ? ".pdf" : ".docx")
        panel.message = "DOCX keeps editing available. PDF keeps the page layout."
        let choice = WriterSaveFormat(panel: panel, pdf: pdf)
        panel.accessoryView = choice.view
        return withExtendedLifetime(choice) { panel.runModal() == .OK ? panel.url : nil }
    }
    func exportCopy() {
        canvas?.window?.makeFirstResponder(nil)
        guard let output = chooseDestination(pdf: false) else { return }
        do { try data(for: output).write(to: output, options: .atomic) } catch { self.error = error.localizedDescription }
    }
    func data(for destination: URL) throws -> Data {
        if destination.pathExtension.lowercased() == "docx" { return try WriterArchive.encode(self) }
        if destination.pathExtension.lowercased() == "pdf", let canvas { return try canvas.pdf() }
        throw ReferenceFailure("Choose DOCX or PDF.")
    }
    func exportPDF(to destination: URL? = nil) {
        canvas?.window?.makeFirstResponder(nil)
        guard let destination = destination ?? chooseDestination(pdf: true), let canvas else { return }
        do { try canvas.pdf().write(to: destination, options: .atomic) } catch { self.error = error.localizedDescription }
    }
    func printDocument() {
        canvas?.window?.makeFirstResponder(nil)
        do {
            guard let canvas, let document = PDFDocument(data: try canvas.pdf()), let operation = document.printOperation(for: NSPrintInfo.shared.copy() as? NSPrintInfo, scalingMode: .pageScaleToFit, autoRotate: true) else { throw ReferenceFailure("Could not prepare this document for printing.") }
            operation.run()
        } catch { self.error = error.localizedDescription }
    }
    func open() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "docx")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await openFile(url) }
    }
    @discardableResult func openFile(_ url: URL) async -> Bool {
        guard !loading, confirmLeaving() else { return false }
        let expected = revision
        loading = true; defer { loading = false }
        do {
            let candidate = WriterModel()
            let own = try await WriterForeignImport.load(url, into: candidate)
            guard revision == expected else { throw ReferenceFailure("The document changed. Open the file again.") }
            load(text: candidate.storage, objects: candidate.objects, paper: candidate.paper, landscape: candidate.landscape, pageStyle: candidate.pageStyle)
            self.url = own ? url : nil; dirty = !own
            if !own { error = "Imported a copy. Some objects may be images." }
            undo.removeAllActions(); selected = nil; revision = UUID(); canvas?.rebuild(); didVisit?(url)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func replaceBody(_ text: NSAttributedString) {
        let before = NSAttributedString(attributedString: storage)
        recordUndo { $0.replaceBody(before) }
        storage.setAttributedString(text); changed(); canvas?.paginate()
    }
    func load(text: NSAttributedString, objects: [WriterObject], paper: String, landscape: Bool, pageStyle: WriterPageStyle = WriterPageStyle()) {
        storage.setAttributedString(text); self.objects = objects; self.paper = paper; self.landscape = landscape; self.pageStyle = pageStyle
    }
    func confirmLeaving(decision: (() -> NSApplication.ModalResponse)? = nil) -> Bool {
        guard !loading else { error = "Wait for the document to open."; return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save this document?"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard")
        switch decision?() ?? alert.runModal() { case .alertFirstButtonReturn: return save(); case .alertSecondButtonReturn: return false; default: return true }
    }
}

@MainActor private final class WriterSaveFormat: NSObject {
    let panel: NSSavePanel
    let popup = NSPopUpButton()
    let view = NSStackView()
    init(panel: NSSavePanel, pdf: Bool) {
        self.panel = panel; super.init()
        popup.addItems(withTitles: ["DOCX", "PDF"]); popup.selectItem(at: pdf ? 1 : 0); popup.target = self; popup.action = #selector(change)
        view.orientation = .horizontal; view.spacing = 10; view.addArrangedSubview(NSTextField(labelWithString: "Format")); view.addArrangedSubview(popup)
        change()
    }
    @objc private func change() {
        let ext = popup.indexOfSelectedItem == 1 ? "pdf" : "docx"
        panel.allowedContentTypes = [UTType(filenameExtension: ext)!]
        panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + ext
    }
}
