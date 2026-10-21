import AppKit
import PDFKit

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label); checks += 1 }
func rejects(_ label: String, _ operation: () throws -> Void) { do { try operation(); preconditionFailure(label) } catch { checks += 1 } }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let bounds = CGRect(x: 80, y: 520, width: 120, height: 40)
for permission in [0, 3] {
    let original = try Data(contentsOf: directory.appendingPathComponent("signed-p\(permission).pdf"))
    let document = PDFDocument(data: original)!, first = document.page(at: 0)!, second = document.page(at: 1)!
    _ = try PDFReplyWriter.File(original)
    let projection = document.dataRepresentation()!
    try projection.write(to: directory.appendingPathComponent("projection-p\(permission).pdf"))
    _ = try PDFReplyWriter.File(projection)
    let graph = PDFCommentGraph(document: document, sourceData: original)
    try graph.validateAnnotationSave()
    let highlight = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
    highlight.color = .yellow
    highlight.quadrilateralPoints = [NSPoint(x: 0, y: 40), NSPoint(x: 120, y: 40), .zero, NSPoint(x: 120, y: 0)].map { NSValue(point: $0) }
    _ = try PDFEditing.apply([(first, highlight)], adding: true, in: document, graph: graph)
    let square = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil); square.color = .systemRed
    let ink = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
    let path = NSBezierPath(); path.move(to: .zero); path.line(to: NSPoint(x: 100, y: 30)); ink.add(path)
    _ = try PDFEditing.apply([(second, square), (second, ink)], adding: true, in: document, graph: graph)
    let note = PDFNotes.make(text: "Signed original retained", author: "Me", bounds: bounds)
    _ = try PDFNotes.apply(note, on: second, in: document, adding: true, graph: graph)
    let reply = PDFNotes.make(text: "Reply", author: "Me", bounds: bounds)
    let output = try PDFNotes.apply(reply, on: second, in: document, adding: true, graph: graph, parent: note)
    expect(output.starts(with: original), "Every signed byte, including the original xref, is unchanged")
    let reopened = PDFDocument(data: output)!
    expect(reopened.page(at: 0)!.annotations.contains { $0.type == "Highlight" }, "Highlight reopens on signed page")
    expect(reopened.page(at: 1)!.annotations.contains { $0.type == "Ink" } && reopened.page(at: 1)!.annotations.contains { $0.type == "Square" }, "Ink and shape reopen on another page")
    expect(PDFCommentGraph(document: reopened).parents.count == 1, "Incremental annotation refs retain replies")
    expect(try! PDFFormPreservation.snapshot(document) == PDFFormPreservation.snapshot(reopened), "Signature and form tree are preserved")
    try output.write(to: directory.appendingPathComponent("annotated-p\(permission).pdf"), options: .atomic)
    let count = output.range(of: Data("startxref".utf8), options: .backwards)!
    expect(count.lowerBound > original.count, "A new xref revision follows the signed original")
    _ = try PDFReplyWriter.File(output)
    _ = try PDFReplyWriter.File(reopened.dataRepresentation()!)
    let reopenedGraph = PDFCommentGraph(document: reopened, sourceData: output)
    try reopenedGraph.validateAnnotationSave()
    let more = PDFNotes.make(text: "Second save", author: "Me", bounds: bounds)
    let again = try PDFNotes.apply(more, on: reopened.page(at: 1)!, in: reopened, adding: true, graph: reopenedGraph)
    expect(again.starts(with: output), "Reopening and saving an incremental chain preserves earlier revisions")
    try again.write(to: directory.appendingPathComponent("twice-p\(permission).pdf"))
    // Saving is an overwrite of the same destination, without user-visible copies.
    let samePath = directory.appendingPathComponent("overwrite-p\(permission).pdf")
    try original.write(to: samePath); try output.write(to: samePath, options: .atomic)
    expect(try! Data(contentsOf: samePath) == output, "Atomic overwrite retains the incremental PDF")
    rejects("Page rotation is never allowed on a signed PDF") { _ = try PDFEditing.rotate(first, to: 90, in: document, graph: graph) }
    second.rotation = 90
    rejects("Bypassing page controls cannot serialise page changes") { _ = try graph.serialize(document) }
    second.rotation = 0
    let undone = try PDFEditing.apply([(first, highlight)], adding: false, in: document, graph: graph)
    expect(undone.starts(with: original) && !PDFDocument(data: undone)!.page(at: 0)!.annotations.contains { $0.type == "Highlight" }, "Annotation removal preserves signed bytes")
    let loadedNote = reopened.page(at: 1)!.annotations.first { $0.contents == "Signed original retained" }!
    loadedNote.contents = "Unexpected mutation"
    rejects("Existing annotation changes outside the supported writer are refused") { _ = try reopenedGraph.serialize(reopened) }
}
for permission in [1, 2] {
    let original = try Data(contentsOf: directory.appendingPathComponent("signed-p\(permission).pdf"))
    let document = PDFDocument(data: original)!, graph = PDFCommentGraph(document: document, sourceData: original)
    rejects("Certification P=1/2 disallows annotations") { try graph.validateAnnotationSave() }
    let page = document.page(at: 0)!, count = page.annotations.count
    let mark = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
    rejects("A forbidden annotation must roll back") { _ = try PDFEditing.apply([(page, mark)], adding: true, in: document, graph: graph) }
    expect(page.annotations.count == count, "Forbidden save leaves live PDF unchanged")
}
let data = try Data(contentsOf: directory.appendingPathComponent("signed-p3.pdf")), document = PDFDocument(data: data)!
rejects("A signed PDF without original bytes cannot enter the rewrite path") { _ = try PDFCommentGraph(document: document).serialize(document) }
let damagedData = try Data(contentsOf: directory.appendingPathComponent("damaged.pdf")), damaged = PDFDocument(data: damagedData)!
rejects("A pre-existing digest mismatch is not attested as preserved") { try PDFCommentGraph(document: damaged, sourceData: damagedData).validateAnnotationSave() }
print("\(checks) signed-PDF checks passed. Fixtures use disposable certificates, not system trust.")
