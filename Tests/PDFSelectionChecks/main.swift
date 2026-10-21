import AppKit
import CoreText
import PDFKit

MainActor.assumeIsolated {
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label); checks += 1
}
func fixture() -> Data {
    let bytes = NSMutableData()
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &bounds, nil)!
    for number in 1...2 {
        context.beginPDFPage(nil)
        let text = NSAttributedString(string: "Physics informed selection page \(number)", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        context.textPosition = CGPoint(x: 72, y: 700); CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
    }
    context.closePDF(); return bytes as Data
}
func invoke(_ item: NSMenuItem) {
    guard let action = item.action else { preconditionFailure("Missing action") }
    NSApplication.shared.sendAction(action, to: item.target, from: item)
}
_ = NSApplication.shared
let bytes = fixture(), document = PDFDocument(data: bytes)!, foreign = PDFDocument(data: bytes)!
let view = PDFSelectionView(frame: CGRect(x: 0, y: 0, width: 700, height: 850))
view.document = document; view.autoScales = true; view.layoutDocumentView()
let page = document.page(at: 0)!, first = page.selection(for: NSRange(location: 0, length: 7))!
let second = page.selection(for: NSRange(location: 8, length: 8))!
let snapshot = PDFSelectionContext(selection: first, document: document)!
expect(snapshot.text == "Physics", "Snapshot captures selected text")
expect(snapshot.pageIndices == [0], "Snapshot records actual page index")
expect(snapshot.selection !== first, "Snapshot owns a native selection copy")
expect(snapshot.isValid(in: view), "Current document identity validates")
expect(PDFSelectionContext(selection: nil, document: document) == nil, "Missing selection rejected")
expect(PDFSelectionContext(selection: PDFSelection(document: document), document: document) == nil, "Empty selection rejected")
expect(PDFSelectionContext(selection: foreign.selectionForEntireDocument, document: document) == nil, "Foreign selection rejected")
expect(PDFSelectionContext(selection: document.selectionForEntireDocument, document: document)?.pageIndices == [0, 1], "Multi-page capture preserves original page indices")

var calls: [String] = [], captured: PDFSelectionContext?, chosen: HighlightColor?
view.selectionActions.highlight = { context, colour in calls.append("highlight"); captured = context; chosen = colour }
view.selectionActions.addNote = { context in calls.append("note"); captured = context }
view.selectionActions.ask = { context in calls.append("ask"); captured = context }
view.selectionActions.translate = { context in calls.append("translate"); captured = context }
var menu = view.selectionMenu(for: first)
expect(menu.items.map(\.title) == ["Copy", "", "Highlight", "Add Note…", "", "Ask about Selection (on-device)", "Translate Selection…"], "Explicit native menu order excludes PDFKit defaults")
expect(!menu.autoenablesItems && menu.items[0].isEnabled, "Valid text enables Copy with explicit validation")
let colours = menu.items[2].submenu!
expect(colours.numberOfItems == HighlightColor.allCases.count, "Highlight includes the shared fixed palette")
expect(colours.items.allSatisfy { $0.image != nil && $0.isEnabled }, "Palette has visible swatches and enabled actions")
view.setCurrentSelection(second, animate: false)
invoke(menu.items[5])
expect(calls == ["ask"] && captured?.text == "Physics", "Ask uses captured selection even when visible selection changes")
expect(captured?.document === document, "Ask remains scoped to the original document")
invoke(colours.items[1])
expect(calls.last == "highlight" && chosen == .orange, "Highlight passes the selected palette colour")
invoke(menu.items[3]); expect(calls.last == "note", "Note invokes its own scoped handler")
invoke(menu.items[6]); expect(calls.last == "translate", "Translate invokes its own scoped handler")
expect(page.annotations.isEmpty, "Menu handlers leave persistence and PDF mutation to callers")

let originalCount = calls.count
view.document = foreign
invoke(menu.items[5]); invoke(menu.items[3]); invoke(colours.items[0]); invoke(menu.items[6])
expect(calls.count == originalCount, "Every delayed callback rejects a replaced PDF")
expect(!snapshot.isValid(in: view), "Snapshot rejects stale view identity")
view.document = document
view.selectionActions.canAnnotate = { _ in false }
menu = view.selectionMenu(for: first)
expect(!menu.items[2].isEnabled && !menu.items[3].isEnabled, "Busy or restricted caller disables markup")
expect(menu.items[5].isEnabled && menu.items[6].isEnabled, "Markup gate does not disable reading actions")
view.selectionActions.canAnnotate = { _ in true }
menu = view.selectionMenu(for: first)
view.selectionActions.canAnnotate = { _ in false }
invoke(menu.items[3]); invoke(menu.items[2].submenu!.items[0])
expect(calls.count == originalCount, "Markup gate is rechecked at dispatch")
view.selectionActions = PDFSelectionActions()
menu = view.selectionMenu(for: first)
expect(!menu.items[2].isEnabled && !menu.items[3].isEnabled && !menu.items[5].isEnabled && !menu.items[6].isEnabled, "Unavailable handlers are visibly disabled")
expect(menu.items[0].isEnabled, "Native copy remains available independently")
menu = view.selectionMenu(for: nil)
expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled }, "No text produces no actionable selection items")

let restrictedBytes = document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader", PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 0)])!
let restricted = PDFDocument(data: restrictedBytes)!
expect(restricted.isLocked, "Permission fixture begins locked")
view.document = restricted
expect(PDFSelectionContext(selection: first, document: restricted) == nil, "Locked document rejects captured text")
_ = restricted.unlock(withPassword: "reader")
expect(!restricted.isLocked && !restricted.allowsCopying, "Unlocked fixture still denies copying")
view.selectionActions.ask = { _ in calls.append("restricted") }
view.selectionActions.translate = { _ in calls.append("restricted") }
view.selectionActions.addNote = { _ in calls.append("restricted") }
view.selectionActions.highlight = { _, _ in calls.append("restricted") }
menu = view.selectionMenu(for: restricted.selectionForEntireDocument)
expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled }, "Copy permission gates extraction and all selected-text actions")
invoke(menu.items[5]); expect(calls.count == originalCount, "Permission guard survives direct target invocation")

let encrypted = PDFDocument(data: document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"])!)!
_ = encrypted.unlock(withPassword: "reader"); view.document = encrypted
menu = view.selectionMenu(for: encrypted.selectionForEntireDocument)
expect(!menu.items[2].isEnabled && !menu.items[3].isEnabled, "Encrypted PDFs cannot enter unsupported markup write paths")

view.document = document; view.setCurrentSelection(first, animate: false)
let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 0, y: 0), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
_ = view.menu(for: event)
expect(view.currentSelection?.string == "Physics", "Opening the menu preserves an existing owned selection")
view.setCurrentSelection(nil, animate: false); view.go(to: page); view.layoutDocumentView()
let bounds = first.bounds(for: page)
let wordPoint = view.convert(NSPoint(x: bounds.midX, y: bounds.midY), from: page)
let location = view.convert(wordPoint, to: nil)
let wordEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
let wordMenu = view.menu(for: wordEvent)!
expect(view.currentSelection?.string == "Physics", "Clicking a word with no current selection captures only that word")
expect(wordMenu.items[0].isEnabled, "Fallback word receives the same permission-checked menu")
let retainedMenu = view.selectionMenu(for: first)
expect(retainedMenu.items[0].target != nil, "Menu items retain their own targets")
view.document = nil
expect(!snapshot.isValid(in: view), "Closing the document invalidates snapshots")
invoke(retainedMenu.items[0])
expect(document.page(at: 0)!.annotations.isEmpty, "No menu action writes or marks the document implicitly")
let reordering = PDFDocument(data: bytes)!, orderView = PDFSelectionView()
orderView.document = reordering
let beforeReorder = PDFSelectionContext(selection: reordering.page(at: 0)!.selection(for: NSRange(location: 0, length: 7)), document: reordering)!
reordering.exchangePage(at: 0, withPageAt: 1)
expect(!beforeReorder.isValid(in: orderView), "Page reordering invalidates old source indices")
view.document = document; view.go(to: page); view.layoutDocumentView()
var drawings: [PDFAnnotation] = []
view.commitDrawing = { owner, annotation in
    expect(owner === page, "Drawing commits to the page where the gesture started")
    drawings.append(annotation)
}
func pointer(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) -> NSEvent {
    let location = view.convert(view.convert(CGPoint(x: x, y: y), from: page), to: nil)
    return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
for tool in PDFDrawingTool.allCases {
    view.drawingTool = tool
    view.mouseDown(with: pointer(.leftMouseDown, x: 100, y: 600))
    for step in 1...40 { view.mouseDragged(with: pointer(.leftMouseDragged, x: 100 + CGFloat(step), y: 600 + CGFloat(step))) }
    expect(page.annotations.isEmpty, "Pointer movement never mutates PDF annotation objects")
    expect(view.layer?.sublayers?.filter { $0 is CAShapeLayer }.count == 1, "One vector preview layer is reused for the complete gesture")
    let count = drawings.count
    view.mouseUp(with: pointer(.leftMouseUp, x: 140, y: 640))
    expect(drawings.count == count + 1, "A gesture produces exactly one annotation at mouse-up")
    expect(view.layer?.sublayers?.contains { $0 is CAShapeLayer } != true, "Preview resources are removed after commit")
}
view.mouseDown(with: pointer(.leftMouseDown, x: 100, y: 600))
view.mouseDragged(with: pointer(.leftMouseDragged, x: 140, y: 640))
let beforeCancel = drawings.count
view.cancelDrawing()
expect(drawings.count == beforeCancel && page.annotations.isEmpty, "Cancelling a gesture retains neither an annotation nor a write")
expect(PDFDrawingTool.rectangle.annotation(points: [.zero, .zero], on: page, color: .red) == nil, "Zero-size shapes are ignored")
print("\(checks) PDF selection checks passed. Synthetic native PDFs; no user file or clipboard change.")
}
