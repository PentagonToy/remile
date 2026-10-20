import AppKit
import CoreText
import PDFKit

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label); checks += 1
}
func rejects(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); preconditionFailure(label) } catch { checks += 1 }
}
func fixture() -> Data {
    let bytes = NSMutableData()
    let consumer = CGDataConsumer(data: bytes)!
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
    for number in 1...2 {
        context.beginPDFPage(nil)
        let text = NSAttributedString(string: "Remile editing fixture page \(number)", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        context.textPosition = CGPoint(x: 72, y: 700); CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
    }
    context.closePDF(); return bytes as Data
}
func catalogFixture(_ entry: String) -> Data {
    let objects = ["<< /Type /Catalog /Pages 2 0 R \(entry) >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"]
    var output = "%PDF-1.4\n", offsets = [0]
    for (i, object) in objects.enumerated() { offsets.append(output.utf8.count); output += "\(i + 1) 0 obj\n\(object)\nendobj\n" }
    let xref = output.utf8.count
    output += "xref\n0 4\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() { output += String(format: "%010d 00000 n \n", offset) }
    output += "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(output.utf8)
}
var escapedName = PDFReplyWriter.Parser(bytes: Array("/Sub#74ype".utf8), index: 0)
expect(try! escapedName.value().name == "Subtype", "Valid hexadecimal name escapes decode before dictionary comparison")
for name in ["/Bad#", "/Bad#GG", "/Bad#00"] {
    rejects("Malformed or null name escapes are rejected") {
        var parser = PDFReplyWriter.Parser(bytes: Array(name.utf8), index: 0); _ = try parser.value()
    }
}
let app = NSApplication.shared
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let original = fixture(), source = directory.appendingPathComponent("source.pdf")
try original.write(to: source)
let session = PDFSession(); session.load(original)
let document = session.document!, page = document.page(at: 0)!
let view = PDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 800)); view.document = document; session.attach(view)
view.go(to: page)
let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
session.toggleEditing(); expect(session.isEditing, "Ordinary PDF opens editing tools")
undo.beginUndoGrouping(); session.rotateCurrentPage(clockwise: true); undo.endUndoGrouping()
expect(page.rotation == 90, "Rotate changes only the current page")
expect(document.page(at: 1)!.rotation == 0, "Other page rotation remains unchanged")
expect(PDFDocument(data: session.committedData!)!.page(at: 0)!.rotation == 90, "Rotation serialises into pending document bytes")
expect((try? Data(contentsOf: source)) == original, "Rotate leaves source bytes unchanged")
let ownBytes = session.committedData!; session.load(ownBytes)
expect(session.document === document && session.isEditing, "Own writeback preserves editor and PDF identity")
undo.undo(); expect(page.rotation == 0, "Rotation undo restores the angle")
undo.redo(); expect(page.rotation == 90, "Rotation redo restores the change")
undo.undo()
view.setCurrentSelection(page.selection(for: page.bounds(for: .mediaBox)), animate: false)
expect(session.canHighlight, "Native owned selection can be highlighted")
undo.beginUndoGrouping(); session.highlightSelection(); undo.endUndoGrouping()
let marks = page.annotations.filter { $0.type == "Highlight" }
expect(marks.count == 1 && marks[0].quadrilateralPoints?.count == 4, "Highlight persists standard quadrilateral geometry")
expect(marks[0].color.alphaComponent == 0.30, "Highlight uses fixed transparent palette colour")
expect(PDFDocument(data: session.committedData!)!.page(at: 0)!.annotations.contains { $0.type == "Highlight" }, "Highlight is present after reopening pending bytes")
undo.undo(); expect(!page.annotations.contains { $0.type == "Highlight" }, "Highlight undo removes markup")
undo.redo(); expect(page.annotations.contains { $0.type == "Highlight" }, "Highlight redo restores markup")
expect((try? Data(contentsOf: source)) == original, "Highlights leave source unchanged")
let foreign = PDFDocument(data: original)!
rejects("Foreign selection is rejected") { _ = try PDFEditing.highlights(for: foreign.selectionForEntireDocument!, in: document) }
let graph = PDFCommentGraph(document: document)
let root = PDFNotes.make(text: "Root", author: "Me", bounds: CGRect(x: 80, y: 600, width: 24, height: 24))
_ = try PDFNotes.apply(root, on: page, in: document, adding: true, graph: graph)
let reply = PDFNotes.make(text: "Reply", author: "Me", bounds: root.bounds)
_ = try PDFNotes.apply(reply, on: page, in: document, adding: true, graph: graph, parent: root)
let rotated = try PDFEditing.rotate(page, to: 270, in: document, graph: graph)
let reopened = PDFDocument(data: rotated)!
expect(PDFCommentGraph(document: reopened).parents.count == 1, "Rotation preserves a standard reply relation")
expect(reopened.page(at: 0)!.string == page.string, "Rotation preserves extracted text")
let broken = PDFCommentGraph(document: document)
let crossPageParent = PDFNotes.make(text: "Cross-page", author: "Me", bounds: root.bounds)
document.page(at: 1)!.addAnnotation(crossPageParent)
broken.add(root, parent: crossPageParent)
let previousRotation = page.rotation
rejects("Unsafe serialisation must fail") { _ = try PDFEditing.rotate(page, to: 0, in: document, graph: broken) }
expect(page.rotation == previousRotation, "Failed rotation rolls back the page")
let failedMarks = try PDFEditing.highlights(for: page.selection(for: page.bounds(for: .mediaBox))!, in: document)
let previousAnnotationCount = page.annotations.count
rejects("Unsafe highlight serialisation must fail") { _ = try PDFEditing.apply(failedMarks, adding: true, in: document, graph: broken) }
expect(page.annotations.count == previousAnnotationCount, "Failed highlights roll back their annotations")
document.page(at: 1)!.removeAnnotation(crossPageParent)
for entry in ["/AcroForm << >>", "/Perms << >>", "/Collection << >>"] {
    let unsafe = PDFDocument(data: catalogFixture(entry))!
    rejects("Form/signature/portfolio catalogue is rejected") { try PDFEditing.validate(unsafe, assembly: true) }
}
let publisher = PDFDocument(data: catalogFixture("/AcroForm << /Fields [] /DA (/Helv 0 Tf 0 g) >>"))!
try PDFEditing.validate(publisher, assembly: true)
expect(publisher.pageCount == 1, "Explicitly empty publisher form metadata permits editing")
for entry in ["/AcroForm << /Fields [<< /FT /Tx >>] >>", "/AcroForm << /Fields [] /SigFlags 1 >>", "/AcroForm << /Fields [] /XFA (payload) >>"] {
    rejects("Actual forms, signatures and XFA remain rejected") { try PDFEditing.validate(PDFDocument(data: catalogFixture(entry))!, assembly: true) }
}
let widgetDocument = PDFDocument(data: original)!
widgetDocument.page(at: 0)!.addAnnotation(PDFAnnotation(bounds: root.bounds, forType: .widget, withProperties: nil))
rejects("Widget forms are rejected") { try PDFEditing.validate(widgetDocument) }
let encrypted = PDFDocument(data: document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"])!)!
rejects("Locked PDF editing is rejected") { try PDFEditing.validate(encrypted) }
_ = encrypted.unlock(withPassword: "reader")
rejects("Unlocked encrypted PDF editing remains rejected") { try PDFEditing.validate(encrypted) }
let operation = try session.makePrintOperation()
expect(operation.showsPrintPanel && operation.showsProgressPanel, "Native print operation prepares a standard print panel")
let lockedSession = PDFSession(); lockedSession.load(document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"])!)
rejects("Locked PDF printing is rejected") { _ = try lockedSession.makePrintOperation() }
let restrictedBytes = PDFDocument(data: original)!.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader", PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 0)])!
let restrictedSession = PDFSession(); restrictedSession.load(restrictedBytes)
restrictedSession.password = "reader"; restrictedSession.unlock()
expect(restrictedSession.document?.isLocked == false && restrictedSession.document?.allowsPrinting == false, "Fixture unlock preserves a denied print permission")
rejects("Unlocked print-restricted PDF is rejected") { _ = try restrictedSession.makePrintOperation() }
restrictedSession.stop()
expect((try? Data(contentsOf: source)) == original, "Print preparation leaves source unchanged")
session.toggleEditing(); expect(!session.isEditing, "Done returns to reading")
session.stop(); lockedSession.stop()
try rotated.write(to: directory.appendingPathComponent("rotated-with-reply.pdf"))
print("\(checks) PDF editing checks passed. Synthetic PDFs only; print panel not opened or printed.")
