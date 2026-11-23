import CoreText
import PDFKit
import SwiftUI
import XCTest
@testable import Remile

@MainActor final class PDFInteroperabilityTests: XCTestCase {
    private func fixture(_ text: String, pages: Int = 2) throws -> Data {
        _ = NSApplication.shared
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<pages {
            writer.beginPDFPage(nil)
            writer.textPosition = CGPoint(x: 72, y: 700)
            let line = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16)])
            CTLineDraw(CTLineCreateWithAttributedString(line), writer)
            writer.endPDFPage()
        }
        writer.closePDF()
        return data as Data
    }

    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remile-pdf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Review.pdf")
    }

    func testMetadataFollowsSymlinksAndDetectsAtomicReplacement() throws {
        let url = try temporaryFile()
        try fixture("First").write(to: url, options: .atomic)
        let link = url.deletingLastPathComponent().appendingPathComponent("Alias.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let version = try PDFFileAccess.Version(link)
        XCTAssertNil(try PDFFileAccess.read(link, since: version))
        let updated = try fixture("Second")
        try updated.write(to: url, options: .atomic)
        XCTAssertEqual(try PDFFileAccess.read(link, since: version)?.data, updated)
    }

    func testExternalRefreshUsesMetadataAndKeepsPendingAnnotations() async throws {
        let url = try temporaryFile(), first = try fixture("Original document")
        try first.write(to: url, options: .atomic)
        let reader = ReadingSession()
        try reader.open(url, recordRecent: false)
        let pdf = PDFSession(); pdf.load(first); reader.pdfSession = pdf
        defer { pdf.stop() }
        let version = try PDFFileAccess.Version(url)
        XCTAssertNil(try PDFFileAccess.read(url, since: version))

        let updated = try fixture("Changed in another app")
        try updated.write(to: url, options: .atomic)
        try await reader.refreshPDFFile()
        XCTAssertEqual(reader.bytes, updated)
        XCTAssertTrue(pdf.document?.string?.contains("Changed in another app") == true)
        XCTAssertFalse(reader.dirty || reader.pdfChangedOutside)

        let page = try XCTUnwrap(pdf.document?.page(at: 0))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.document = pdf.document; pdf.attach(view)
        pdf.beginComment(); pdf.draft = "Keep this note"; pdf.author = "Reader"; pdf.saveComment()
        let note = try XCTUnwrap(page.annotations.first { $0.contents == "Keep this note" })
        XCTAssertTrue(reader.dirty)
        let secondUpdate = try fixture("Another external edit")
        try secondUpdate.write(to: url, options: .atomic)
        try await reader.refreshPDFFile()
        XCTAssertTrue(reader.pdfChangedOutside)
        XCTAssertTrue(page.annotations.contains { $0 === note })
        XCTAssertEqual(reader.bytes, updated)

        try await reader.refreshPDFFile(discardingLocalChanges: true)
        XCTAssertEqual(reader.bytes, secondUpdate)
        XCTAssertFalse(reader.pdfChangedOutside || reader.dirty)
        XCTAssertTrue(pdf.document?.page(at: 0)?.annotations.isEmpty == true)
    }

    func testUnfinishedNoteAndInvalidExternalFileArePreserved() async throws {
        let url = try temporaryFile(), original = try fixture("Original")
        try original.write(to: url, options: .atomic)
        let reader = ReadingSession(); try reader.open(url, recordRecent: false)
        let session = PDFSession(); session.load(original); reader.pdfSession = session
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800)); view.document = session.document; session.attach(view)
        defer { session.stop() }
        session.beginComment(); session.draft = "Unfinished note"
        XCTAssertNotNil(session.draftContext)
        try fixture("External edit").write(to: url, options: .atomic)
        try await reader.refreshPDFFile()
        XCTAssertEqual(session.draft, "Unfinished note")
        XCTAssertEqual(reader.bytes, original)
        XCTAssertTrue(reader.pdfChangedOutside)

        session.cancelComment()
        try Data("not a PDF".utf8).write(to: url, options: .atomic)
        do { try await reader.refreshPDFFile(); XCTFail("A corrupt replacement must not replace the open PDF") }
        catch { XCTAssertEqual(reader.bytes, original) }
        XCTAssertEqual(session.document?.pageCount, 2)
    }

    func testRefreshKeepsTheVisiblePDFDestination() async throws {
        let defaults = UserDefaults.standard, savedMarkers = UserDefaults.standard.object(forKey: "pdf.readingPositions")
        defer { defaults.set(savedMarkers, forKey: "pdf.readingPositions") }
        func reviewed(_ text: String) throws -> Data {
            let document = try XCTUnwrap(PDFDocument(data: fixture(text, pages: 3)))
            let graph = PDFCommentGraph(document: document), page = try XCTUnwrap(document.page(at: 0))
            let note = PDFNotes.make(text: "Review this evidence", author: "Ada", bounds: CGRect(x: 400, y: 600, width: 24, height: 24))
            page.addAnnotation(note); graph.add(note, parent: nil)
            return try graph.serialize(document)
        }
        let url = try temporaryFile(), bytes = try reviewed("Original")
        try bytes.write(to: url, options: .atomic)
        let reader = ReadingSession(); try reader.open(url, recordRecent: false)
        let session = PDFSession(); session.sidebar = .comments; session.showsSidebar = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        let controller = NSHostingController(rootView: RefreshReaderHost(reader: reader, session: session))
        controller.sizingOptions = []; window.contentViewController = controller
        window.setContentSize(NSSize(width: 1100, height: 720))
        controller.view.layoutSubtreeIfNeeded()
        defer { session.stop(); window.orderOut(nil) }
        func pdfView(_ view: NSView) -> PDFView? {
            if let pdf = view as? PDFView { return pdf }
            return view.subviews.lazy.compactMap(pdfView).first
        }
        for _ in 0..<20 where pdfView(controller.view)?.document == nil { try await Task.sleep(for: .milliseconds(10)) }
        let view = try XCTUnwrap(pdfView(controller.view))
        for _ in 0..<30 where view.autoScales { try await Task.sleep(for: .milliseconds(10)) }
        view.layoutDocumentView()
        let page = try XCTUnwrap(session.document?.page(at: 1))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 760)))
        let before = try XCTUnwrap(view.currentDestination)
        XCTAssertTrue(before.page === page)
        session.persistReadingPosition()
        let updated = try reviewed("External edit")
        try updated.write(to: url, options: .atomic)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        for _ in 0..<100 {
            if reader.bytes == updated, view.document === session.document, let destination = view.currentDestination,
               destination.page === session.document?.page(at: 1), abs(destination.point.y - before.point.y) < 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let after = try XCTUnwrap(view.currentDestination)
        XCTAssertTrue(after.page === session.document?.page(at: 1))
        XCTAssertEqual(after.point.y, before.point.y, accuracy: 2)
    }

    func testRefreshCannotApplyAfterCancellationOrDocumentSwitch() async throws {
        let url = try temporaryFile(), original = try fixture("Original")
        try original.write(to: url, options: .atomic)
        let reader = ReadingSession(); try reader.open(url, recordRecent: false)
        try fixture("External edit").write(to: url, options: .atomic)
        let pending = Task { try await reader.refreshPDFFile() }
        await Task.yield()
        reader.cancelPDFRefresh()
        XCTAssertTrue(reader.newMarkdown())
        reader.document.content = .markdown("Keep writing")
        _ = try? await pending.value
        XCTAssertEqual(String(data: reader.bytes, encoding: .utf8), "Keep writing")
        XCTAssertFalse(reader.pdfChangedOutside)
    }

    func testPlainHighlightHasQuoteWithoutCommentAndRetainsAuthoredComment() throws {
        let document = try XCTUnwrap(PDFDocument(data: fixture("Selected text and other words")))
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 13)))
        let marks = try PDFEditing.highlights(for: selection, in: document)
        let mark = try XCTUnwrap(marks.first?.1)
        page.addAnnotation(mark)
        XCTAssertNil(mark.contents)
        XCTAssertEqual(PDFSelectionText.quote(for: mark, on: page), "Selected text")
        XCTAssertFalse(PDFSession.isReviewComment(mark))
        mark.contents = "An authored comment"
        XCTAssertTrue(PDFSession.isReviewComment(mark))
        let archive = try PDFCommentExport.capture(document, name: "Review")
        XCTAssertEqual(archive.comments.first?.text, "An authored comment")
        XCTAssertEqual(archive.comments.first?.quote, "Selected text")
        let first = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 8)))
        let last = try XCTUnwrap(page.selection(for: (page.string! as NSString).range(of: "words")))
        let separated = try PDFEditing.highlights(regions: [(page, first.bounds(for: page), "Selected"), (page, last.bounds(for: page), "words")], in: document, color: .yellow)
        XCTAssertEqual(PDFSelectionText.quote(for: try XCTUnwrap(separated.first?.1), on: page), "Selected words")
    }

    func testAsyncReplyImportAndSearchKeepTheWholeConversation() async throws {
        let source = try XCTUnwrap(PDFDocument(data: fixture("Review", pages: 32)))
        let page = try XCTUnwrap(source.page(at: 0))
        let graph = PDFCommentGraph(document: source)
        let root = PDFNotes.make(text: "Check the evidence", author: "Ada", bounds: CGRect(x: 72, y: 600, width: 24, height: 24))
        let reply = PDFNotes.make(text: "Citation added", author: "Grace", bounds: root.bounds)
        page.addAnnotation(root); graph.add(root, parent: nil)
        page.addAnnotation(reply); graph.add(reply, parent: root)
        let bytes = try graph.serialize(source)
        let imported = try XCTUnwrap(PDFDocument(data: bytes))
        var servicedMainActor = false
        let heartbeat = Task { @MainActor in servicedMainActor = true }
        let asynchronous = try await PDFCommentGraph.importing(document: imported, sourceData: bytes)
        XCTAssertTrue(servicedMainActor)
        await heartbeat.value
        let annotations = try XCTUnwrap(imported.page(at: 0)).annotations.filter { $0.type == "Text" }
        let parent = try XCTUnwrap(annotations.first { $0.contents == root.contents })
        let child = try XCTUnwrap(annotations.first { $0.contents == reply.contents })
        XCTAssertEqual(asynchronous.parent(of: child), ObjectIdentifier(parent))
        let reopened = try XCTUnwrap(PDFDocument(data: asynchronous.serialize(imported)))
        XCTAssertEqual(try PDFCommentExport.capture(reopened, name: "Review").comments.count, 2)

        let session = PDFSession(); session.load(bytes); session.loadComments()
        defer { session.stop() }
        for _ in 0..<200 where session.loadingComments { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(session.loadingComments)
        session.noteQuery = "citation"
        XCTAssertEqual(session.visibleThreads.count, 1)
        XCTAssertEqual(session.visibleThreads.first?.root.text, root.contents)
        XCTAssertEqual(session.visibleThreads.first?.replies.count, 1)
        session.noteQuery = "ada"
        XCTAssertEqual(session.visibleThreads.first?.replies.count, 1)
        session.noteQuery = "missing"
        XCTAssertTrue(session.visibleThreads.isEmpty)
        session.noteQuery = ""
        XCTAssertEqual(session.visibleThreads.count, 1)

        let cancelled = Task { try await PDFCommentGraph.importing(document: imported, sourceData: bytes) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled imports must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private struct RefreshReaderHost: View {
    @ObservedObject var reader: ReadingSession
    let session: PDFSession
    var body: some View {
        PDFWorkspace(data: reader.bytes, fileURL: reader.url, session: session, readingSession: reader,
                     updateDocument: { reader.document.content = .pdf($0) })
    }
}
