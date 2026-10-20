import AppKit
import Combine
import PDFKit

var sessionChecks = 0
func verify(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
    sessionChecks += 1
}
let app = NSApplication.shared
let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("threaded.pdf")
let model = PDFSession()
model.load(try Data(contentsOf: url))
let liveDocument = model.document!
let page = liveDocument.page(at: 0)!
let view = PDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
view.document = liveDocument
model.attach(view)
view.setCurrentSelection(page.selection(for: page.bounds(for: .mediaBox)), animate: false)
verify(model.assistantSelection?.page == 1 && model.assistantSelection?.text.contains("Deerstalker") == true, "Ask captures only selected text owned by the current reader")
let foreignDocument = PDFDocument(data: try Data(contentsOf: url))!
let foreignPage = foreignDocument.page(at: 0)!
view.document = foreignDocument
view.setCurrentSelection(foreignPage.selection(for: foreignPage.bounds(for: .mediaBox)), animate: false)
verify(model.currentPage == 1, "A stale PDFView page notification cannot corrupt reader navigation")
verify(model.assistantSelection == nil, "Ask rejects selections from a stale foreign PDF view")
view.document = liveDocument
view.setCurrentSelection(page.selection(for: page.bounds(for: .mediaBox)), animate: false)
let undo = UndoManager()
undo.groupsByEvent = false
model.undoManager = undo
var writes = 0
let observation = model.$committedData.compactMap { $0 }.sink { _ in writes += 1 }
model.beginComment()
model.draft = "Session note"
undo.beginUndoGrouping()
model.saveComment()
undo.endUndoGrouping()
verify(writes == 1 && model.committedData != nil, "Note commits into document pipeline")
verify(model.draft.isEmpty && model.draftContext == nil, "Successful save clears draft")
let ownCommit = model.committedData!
model.load(ownCommit)
verify(model.document === liveDocument, "Own writeback preserves PDF identity and reading state")
let addedCount = page.annotations.filter { $0.type == "Text" }.count
undo.undo()
verify(page.annotations.filter { $0.type == "Text" }.count == addedCount - 1, "Undo removes the note")
verify(writes == 2, "Undo updates document pipeline")
undo.redo()
verify(page.annotations.filter { $0.type == "Text" }.count == addedCount, "Redo restores the note")
let parent = page.annotations.first { $0.type == "Text" && $0.contents == "First reply" }!
let comment = PDFSession.Comment(id: ObjectIdentifier(parent), annotation: parent, page: page, pageNumber: 1, author: "Reviewer", text: parent.contents!, parent: nil)
model.beginReply(comment)
model.draft = "Session reply"
let capturedContext = model.draftContext
model.beginReply(comment)
verify(model.draft == "Session reply" && model.draftContext == capturedContext, "Second reply command retains draft and parent")
undo.beginUndoGrouping()
model.saveComment()
undo.endUndoGrouping()
let replyBytes = model.committedData!
let reopened = PDFDocument(data: replyBytes)!
verify(PDFCommentGraph(document: reopened).parents.count == 4, "Session reply persists alongside imported replies")
undo.undo()
verify(PDFCommentGraph(document: PDFDocument(data: model.committedData!)!).parents.count == 3, "Reply undo preserves imported thread")
undo.redo()
verify(PDFCommentGraph(document: PDFDocument(data: model.committedData!)!).parents.count == 4, "Reply redo restores parent relation")
func waitUntil(_ done: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}
model.query = "Deerstalker"
model.search()
waitUntil { !model.searching }
verify(model.matches.count == 1, "Async document search finds the page text")
model.query = "Deerstalker"
model.search()
model.query = "no-such-search-token"
model.search()
waitUntil { !model.searching }
verify(model.matches.isEmpty, "Replacing a query discards stale results")
model.query = "Deerstalker"
model.search()
model.stop()
RunLoop.current.run(until: Date().addingTimeInterval(0.35))
verify(!model.searching && model.matches.isEmpty, "Stopping cancels delayed search")
model.loadComments()
waitUntil { !model.loadingComments }
verify(model.threads.contains { $0.replies.count == 4 }, "Reply cards group beneath the original root")
model.stop()
let destinationSession = PDFSession()
destinationSession.load(try Data(contentsOf: url))
destinationSession.revealLibraryPage(1, terms: ["Deerstalker"])
let destinationView = PDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
destinationView.document = destinationSession.document
destinationSession.attach(destinationView)
verify(destinationSession.currentPage == 1, "Pending library destination applies when reader attaches")
verify(destinationView.highlightedSelections?.isEmpty == false, "Library terms highlight on destination page")
let annotationCount = destinationSession.document!.page(at: 0)!.annotations.count
let excerpt = destinationSession.document!.page(at: 0)!.string!
destinationSession.revealLibraryPage(1, terms: [], excerpt: excerpt)
verify(destinationView.highlightedSelections?.isEmpty == false && destinationSession.citationStatus == nil, "A citation highlights its actual supplied passage")
verify(destinationSession.document!.page(at: 0)!.annotations.count == annotationCount && destinationSession.committedData == nil, "Citation focus neither adds annotations nor dirties the PDF")
destinationSession.revealLibraryPage(1, terms: [], excerpt: "An entirely different passage with no corresponding evidence")
verify(destinationView.highlightedSelections?.isEmpty != false && destinationSession.citationStatus != nil, "A stale citation moves to the page but does not fabricate a highlight")
destinationSession.revealLibraryPage(1, terms: [], excerpt: excerpt)
verify(destinationView.highlightedSelections?.isEmpty == false && destinationSession.citationStatus == nil, "Selecting the same citation again restores focus and clears a stale warning")
destinationSession.revealLibraryPage(0, terms: [])
verify(destinationSession.currentPage == 1, "Invalid destination cannot move the reader")
destinationSession.stop()
let protectedSession = PDFSession()
let encryptedBytes = PDFDocument(data: try Data(contentsOf: url))!.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"])!
protectedSession.load(encryptedBytes)
protectedSession.password = "reader"; protectedSession.unlock()
verify(protectedSession.document?.isLocked == false, "Reader unlocks the encrypted fixture")
verify(protectedSession.password.isEmpty && protectedSession.assistantPassword == "reader", "Ask retains only the successful reader unlock credential in memory")
protectedSession.load(try Data(contentsOf: url))
verify(protectedSession.assistantPassword.isEmpty, "Replacing the PDF discards its unlock credential")
protectedSession.stop()
let pending = PDFSession(); pending.load(try Data(contentsOf: url))
pending.revealLibraryPage(1, terms: [], excerpt: "Deerstalker")
let replacement = PDFDocument(); replacement.insert(PDFPage(), at: 0)
pending.load(replacement.dataRepresentation()!)
let replacedView = PDFView(); replacedView.document = pending.document; pending.attach(replacedView)
verify(pending.activeCitation == nil && pending.citationStatus == nil, "Replacing a PDF discards a citation pending before the view attached")
pending.stop()
print("Passed \(sessionChecks) session checks: document writeback, drafts, undo/redo, asynchronous search and thread grouping. Offscreen native views only.")
