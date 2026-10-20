import AppKit
import CoreText
import PDFKit

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

let buffer = NSMutableData()
var bounds = CGRect(x: 0, y: 0, width: 500, height: 600)
let context = CGContext(consumer: CGDataConsumer(data: buffer)!, mediaBox: &bounds, nil)!
context.beginPDFPage(nil)
context.textPosition = CGPoint(x: 40, y: 500)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Remile keeps document text.", attributes: [.font: NSFont.systemFont(ofSize: 15)]))
CTLineDraw(line, context)
context.endPDFPage()
context.closePDF()
let document = PDFDocument(data: buffer as Data)!
let page = document.page(at: 0)!
let originalText = page.string
let noteGraph = PDFCommentGraph(document: document)
let existing = PDFAnnotation(bounds: CGRect(x: 40, y: 440, width: 80, height: 18), forType: .highlight, withProperties: nil)
existing.contents = "Existing highlight"
page.addAnnotation(existing)
noteGraph.add(existing, parent: nil)
let note = PDFNotes.make(text: "수식 검토 — α² + β²", author: "Reviewer", bounds: CGRect(x: 160, y: 450, width: 24, height: 24))
let added = try PDFNotes.apply(note, on: page, in: document, adding: true, graph: noteGraph)
let reopened = PDFDocument(data: added)!
let notes = reopened.page(at: 0)!.annotations.filter { $0.type == "Text" }
check(notes.count == 1, "One note survives serialisation without counting popup annotations")
check(notes.first?.contents == note.contents, "Unicode comment round trip")
check(notes.first?.userName == "Reviewer", "Author round trip")
check(notes.first?.modificationDate != nil, "Date round trip")
check(notes.first?.bounds == note.bounds, "Anchor rectangle round trip")
check(reopened.page(at: 0)?.string == originalText, "Page text preserved")
check(reopened.page(at: 0)!.annotations.contains { $0.type == "Highlight" && $0.contents == "Existing highlight" }, "Existing annotation preserved")
let removed = try PDFNotes.apply(note, on: page, in: document, adding: false, graph: noteGraph)
check(!PDFDocument(data: removed)!.page(at: 0)!.annotations.contains { $0.type == "Text" }, "Undo mutation survives reopen")
let restored = try PDFNotes.apply(note, on: page, in: document, adding: true, graph: noteGraph)
check(PDFDocument(data: restored)!.page(at: 0)!.annotations.filter { $0.type == "Text" }.count == 1, "Redo mutation survives reopen")
check(PDFNotes.make(text: "Note", author: "  ", bounds: .zero).userName == "Me", "No implicit system identity")
if CommandLine.arguments.count > 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let protectedURL = output.appendingPathComponent("protected-fixture.pdf")
    check(document.write(to: protectedURL, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader"]), "Create encrypted fixture")
    let protected = PDFDocument(url: protectedURL)!
    check(protected.isEncrypted && protected.isLocked, "Fixture is password protected")
    check(protected.unlock(withPassword: "reader"), "Unlock controlled fixture")
    let protectedPage = protected.page(at: 0)!
    let previousCount = protectedPage.annotations.count
    var rejected = false
    do { _ = try PDFNotes.apply(note, on: protectedPage, in: protected, adding: true, graph: PDFCommentGraph(document: protected)) }
    catch PDFNotes.Failure.encrypted { rejected = true }
    catch PDFNotes.Failure.restricted { rejected = true }
    check(rejected, "Encrypted annotation editing rejected rather than losing encryption")
    check(protectedPage.annotations.count == previousCount, "Rejected edit leaves annotations unchanged")
}

let markdown = "# Title\n\nA **bold** and *italic* line.\n\n- First\n- Second\n\n> Quote\n\n```swift\nlet n = 1\n```\n"
let blocks = MarkdownBlock.parse(markdown)
check(blocks.count == 6, "Heading, paragraph, two list items, quote and code")
check(Set(blocks.map(\.id)).count == blocks.count, "Stable unique block identities")
check(blocks.map { String($0.text.characters) }.contains("A bold and italic line."), "Inline runs stay in their paragraph")
check(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Bold formatting retained")
if case .heading(1) = blocks[0].style { checks += 1 } else { preconditionFailure("Heading style") }
if case .list("•", 1) = blocks[2].style { checks += 1 } else { preconditionFailure("List style") }
if case .quote = blocks[4].style { checks += 1 } else { preconditionFailure("Quote style") }
if case .code = blocks[5].style { checks += 1 } else { preconditionFailure("Code style") }
check(MarkdownBlock.parse("").isEmpty, "Empty document")
let nested = MarkdownBlock.parse("1. Outer\n   - Inner\n")
if case .list("•", 2) = nested.last?.style { checks += 1 } else { preconditionFailure("Nearest list controls marker") }
let threaded = PDFDocument(data: restored)!
let threadPage = threaded.page(at: 0)!
let root = threadPage.annotations.first { $0.type == "Text" }!
let graph = PDFCommentGraph(document: threaded)
let reply = PDFNotes.make(text: "First reply", author: "Second reviewer", bounds: root.bounds)
_ = try PDFNotes.apply(reply, on: threadPage, in: threaded, adding: true, graph: graph, parent: root)
let nestedReply = PDFNotes.make(text: "Nested reply", author: "Third reviewer", bounds: root.bounds)
let nestedBytes = try PDFNotes.apply(nestedReply, on: threadPage, in: threaded, adding: true, graph: graph, parent: reply)
let nestedDocument = PDFDocument(data: nestedBytes)!
let nestedPage = nestedDocument.page(at: 0)!
let importedGraph = PDFCommentGraph(document: nestedDocument)
let importedRoot = nestedPage.annotations.first { $0.type == "Text" && $0.contents == root.contents }!
let importedReply = nestedPage.annotations.first { $0.type == "Text" && $0.contents == "First reply" }!
let importedNested = nestedPage.annotations.first { $0.type == "Text" && $0.contents == "Nested reply" }!
check(importedGraph.parent(of: importedReply) == ObjectIdentifier(importedRoot), "Imported reply points to the actual page annotation")
check(importedGraph.parent(of: importedNested) == ObjectIdentifier(importedReply), "Nested parent relation survives reopen")
let sibling = PDFNotes.make(text: "Sibling reply", author: "Fourth reviewer", bounds: root.bounds)
let finalBytes = try PDFNotes.apply(sibling, on: nestedPage, in: nestedDocument, adding: true, graph: importedGraph, parent: importedRoot)
let finalDocument = PDFDocument(data: finalBytes)!
let finalGraph = PDFCommentGraph(document: finalDocument)
check(finalGraph.parents.count == 3, "Repeated save retains all three reply links")
let undoneReply = try PDFNotes.apply(sibling, on: nestedPage, in: nestedDocument, adding: false, graph: importedGraph, parent: importedRoot)
check(PDFCommentGraph(document: PDFDocument(data: undoneReply)!).parents.count == 2, "Undo removes only the sibling reply")
let redoneReply = try PDFNotes.apply(sibling, on: nestedPage, in: nestedDocument, adding: true, graph: importedGraph, parent: importedRoot)
check(PDFCommentGraph(document: PDFDocument(data: redoneReply)!).parents.count == 3, "Redo restores the reply relationship")
if CommandLine.arguments.count > 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try finalBytes.write(to: output.appendingPathComponent("threaded.pdf"))
    try redoneReply.write(to: output.appendingPathComponent("threaded-redo.pdf"))
}
let originalCount = nestedPage.annotations.filter { $0.type != "Popup" }.count
var refusedRootRemoval = false
do { _ = try PDFNotes.apply(importedRoot, on: nestedPage, in: nestedDocument, adding: false, graph: importedGraph) }
catch { refusedRootRemoval = true }
check(refusedRootRemoval, "A parent cannot disappear while replies still reference it")
check(nestedPage.annotations.filter { $0.type != "Popup" }.count == originalCount, "Failed parent removal rolls back")
let afterRollback = try importedGraph.serialize(nestedDocument)
check(PDFCommentGraph(document: PDFDocument(data: afterRollback)!).parents.count == 3, "Rollback preserves the thread graph")
var rejectedMalformed = false
do { _ = try PDFReplyWriter.File(Data("%PDF-1.7\nstartxref\n999999\n%%EOF".utf8)) }
catch { rejectedMalformed = true }
check(rejectedMalformed, "Malformed xref rejected")
var rejectedStream = false
do { _ = try PDFReplyWriter.File(Data("%PDF-1.7\n1 0 obj << /Type /XRef >> endobj\nstartxref\n9\n%%EOF".utf8)) }
catch { rejectedStream = true }
check(rejectedStream, "Xref streams refused by the bounded rewrite reader")
let cycle = PDFCommentGraph(document: finalDocument)
let cycleAnnotations = finalDocument.page(at: 0)!.annotations.filter { $0.type == "Text" }
let cycleRoot = cycleAnnotations.first { $0.contents == root.contents }!
let cycleChild = cycleAnnotations.first { $0.contents == "First reply" }!
cycle.add(cycleRoot, parent: cycleChild)
var rejectedCycle = false
do { _ = try cycle.serialize(finalDocument) } catch { rejectedCycle = true }
check(rejectedCycle, "Cyclic parent graph rejected")
var rejectedForeignGraph = false
do { _ = try finalGraph.serialize(nestedDocument) } catch { rejectedForeignGraph = true }
check(rejectedForeignGraph, "A reply graph cannot be used for a different document")
if CommandLine.arguments.count > 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let independentURL = folder.appendingPathComponent("independent-input.pdf")
    if FileManager.default.fileExists(atPath: independentURL.path) {
        let independent = PDFDocument(url: independentURL)!
        let independentPage = independent.page(at: 0)!
        let independentParent = independentPage.annotations.first { $0.contents == "Independent parent" }!
        let independentChild = independentPage.annotations.first { $0.contents == "Independent reply" }!
        let independentGraph = PDFCommentGraph(document: independent)
        check(independentGraph.parent(of: independentChild) == ObjectIdentifier(independentParent), "Import independently generated standard reply")
        let additional = PDFNotes.make(text: "Independent sibling", author: "Reviewer", bounds: independentParent.bounds)
        let rewritten = try PDFNotes.apply(additional, on: independentPage, in: independent, adding: true, graph: independentGraph, parent: independentParent)
        check(PDFCommentGraph(document: PDFDocument(data: rewritten)!).parents.count == 2, "Imported thread survives a new sibling")
        try rewritten.write(to: folder.appendingPathComponent("independent-output.pdf"))
    }
}
print("Passed \(checks) model checks; PDFKit round trips only, no cross-app UI claim.")
