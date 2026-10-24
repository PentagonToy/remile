import AppKit
import SwiftUI
import PDFKit
import CoreText

@_cdecl("__isPlatformVersionAtLeast")
public func citationHostVersion(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
@MainActor final class SearchPreviewFixtureState: ObservableObject {
    @Published var ask = false
    let editing = SearchPDFModel()
    let revision = UUID()
}
struct SearchPreviewFixture: View {
    @ObservedObject var state: SearchPreviewFixtureState
    let hit: LibraryHit
    var body: some View {
        SearchPreviewSplit(askPresented: state.ask, label: "synthetic live search Ask", assistant: { Text("Ask").frame(maxWidth: .infinity, maxHeight: .infinity) }, preview: {
            SearchPDFPreview(hit: hit, query: "evidence", revision: state.revision, open: { _ in }, editing: state.editing)
        })
    }
}
NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("\\documentclass{article}\n\\begin{document}\n\\cite{k\n\\end{document}".utf8).write(to: root.appendingPathComponent("main.tex"))
        let existing = "@article{known, title={Existing evidence}, year={2025}, abstract={Spectral {Galerkin} advection and stability}}\n"
        try Data(existing.utf8).write(to: root.appendingPathComponent("existing.bib"))
        let repository = ReferenceRepository(root: root.appendingPathComponent("catalogue"))
        let record = try repository.add([ReferenceRecord(key: "keyExample", fields: ["title": "A synthetic source", "author": "Key, Example", "year": "2026", "abstract": "Wall stress and turbulence closure learning."])])[0]
        let context = root.path
        ReferenceCitationPreferences.write(.init(library: record.library, bibliography: "existing.bib"), context: context)
        defer { UserDefaults.standard.removeObject(forKey: ReferenceCitationPreferences.key(context)) }
        let project = try TeXProject(root, historyEnabled: false)
        let session = ReferenceCitationSession(context: context, repository: repository)
        let controller = MarkdownEditorController(), scroll = controller.makeView()
        controller.texTheme = .remile
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        controller.changed = { project.buffers["main.tex"] = $0 }
        controller.update(project.buffers["main.tex"]!, size: 17, serif: false, document: "main.tex")
        let view = controller.textView!, caret = (view.string as NSString).range(of: "\\cite{k").location + 7
        view.setSelectedRange(NSRange(location: caret, length: 0)); window.makeFirstResponder(view)
        guard let completion = await session.completion(source: view.string, selection: view.selectedRange(), buffers: project.buffers) else { fatalError("No citation completion") }
        guard let libraryIndex = completion.items.firstIndex(where: { $0.referenceID == record.id }) else { fatalError("Chosen library is unreachable") }
        precondition(completion.items.first?.label == "known", "Citation rows show only the key")
        precondition(completion.items.first?.detail?.contains("Existing evidence") == true, "Selected citation retains readable metadata")
        precondition(completion.items.first?.referenceID == nil, "Existing project bibliography is suggested first")
        for (query, key) in [("galerkin", "known"), ("synthetic source", record.citationKey), ("closure learning", record.citationKey), ("synthetic turbulence", record.citationKey)] {
            let source = "\\cite{" + query
            let result = await session.completion(source: source, selection: NSRange(location: source.utf16.count, length: 0), buffers: project.buffers)
            precondition(result?.items.contains { $0.label == key && $0.insertion == key + "}" } == true, "Project/library title and abstract queries insert only a citation key")
        }
        for _ in 0..<12 { _ = await session.completion(source: view.string, selection: view.selectedRange(), buffers: project.buffers) }
        precondition(session.libraryLoads == 1 && session.bibliographyPreparations == 1, "Typing reuses prepared catalogue and bibliography")
        let panel = EditorCompletionPanel()
        panel.show(in: view, tex: true, custom: completion, prepare: { try session.prepare($0, project: project) }, failure: { fatalError($0) })
        precondition(panel.visible, "Native completion panel appears")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        for _ in 0..<libraryIndex { precondition(panel.key(down)) }
        precondition(panel.key(event), "Return accepts completion")
        precondition(view.string.contains("\\cite{" + record.citationKey + "}"), "Accepted key is inserted with one closing brace")
        precondition(project.buffers["existing.bib"]!.hasPrefix(existing), "Existing bibliography remains byte-for-byte intact")
        let entries = try ReferenceBibTeX.parse(project.buffers["existing.bib"]!)
        precondition(entries.contains { $0.citationKey == record.citationKey }, "Library reference reaches existing bibliography")
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("remile-references.bib").path), "No second bibliography")
        view.undoManager?.undo()
        precondition(view.string.contains("\\cite{k\n"), "Undo restores typed prefix")
        precondition(project.buffers["existing.bib"]!.contains(record.citationKey), "Undo never deletes bibliography entries")
        precondition(!panel.visible, "Completion panel dismisses")
        let beforeRefresh = session.bibliographyPreparations
        _ = await session.completion(source: "\\cite{k", selection: NSRange(location: 7, length: 0), buffers: project.buffers)
        precondition(session.bibliographyPreparations == beforeRefresh + 1 && session.libraryLoads == 1, "Only changed bibliography buffers are prepared again")
        session.release()
        weak var releasedSession: ReferenceCitationSession?
        var temporary: ReferenceCitationSession? = ReferenceCitationSession(context: context, repository: repository)
        releasedSession = temporary
        _ = await temporary?.completion(source: "\\cite{k", selection: NSRange(location: 7, length: 0), buffers: project.buffers)
        temporary = nil
        precondition(releasedSession == nil, "Completed citation tasks do not retain the session")
        let pdfBytes = NSMutableData()
        var pageBox = CGRect(x: 0, y: 0, width: 400, height: 500)
        let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfBytes)!, mediaBox: &pageBox, nil)!
        pdfContext.beginPDFPage(nil); pdfContext.textPosition = CGPoint(x: 40, y: 420)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Synthetic source evidence.", attributes: [.font: NSFont.systemFont(ofSize: 14)])), pdfContext)
        pdfContext.endPDFPage(); pdfContext.closePDF()
        let pdfURL = root.appendingPathComponent("source.pdf")
        try (pdfBytes as Data).write(to: pdfURL)
        let evidenceRecord = try repository.importFiles([pdfURL])[0], attachment = evidenceRecord.attachments[0]
        let testPDF = PDFDocument(data: pdfBytes as Data)!
        let reader = ReferencePDFReader()
        var hosting: NSHostingView<ReferencePDFPreview>? = NSHostingView(rootView: ReferencePDFPreview(data: testPDF.dataRepresentation()!, reader: reader, source: attachment))
        window.contentView = hosting; hosting?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        precondition(reader.view?.document != nil, "Source preview loads its PDF")
        var sourcePage = reader.view!.document!.page(at: 0)
        let quoteRange = (sourcePage!.string! as NSString).range(of: "Synthetic source evidence.")
        precondition(quoteRange.location != NSNotFound, "Synthetic PDF has selectable text")
        reader.view?.setCurrentSelection(sourcePage!.selection(for: quoteRange), animate: false)
        // The fixture must release its page before checking the document's lifetime.
        sourcePage = nil
        let selection = try reader.selection()
        precondition(selection.page == 1 && selection.range == quoteRange, "PDF selection supplies its exact page and range")
        let passage = try ReferencePassages.save(recordID: evidenceRecord.id, attachmentID: attachment.id, expectedSHA256: attachment.sha256, page: selection.page, range: selection.range, repository: repository)
        reader.view?.clearSelection(); reader.reveal(passage)
        precondition(reader.view?.currentSelection?.string == passage.text, "Saved evidence returns to and highlights the source text")
        var unrelated = passage; unrelated.id = UUID()
        let otherAttachment = ReferenceAttachment(id: UUID(), name: attachment.name, sha256: attachment.sha256, bytes: attachment.bytes)
        reader.source = otherAttachment; reader.view?.clearSelection(); reader.reveal(unrelated)
        precondition(reader.view?.currentSelection == nil, "Evidence never highlights a different attachment")
        reader.source = attachment
        weak var releasedPDF = reader.view?.document
        window.contentView = NSView(); hosting = nil
        for _ in 0..<20 where releasedPDF != nil { try await Task.sleep(for: .milliseconds(25)) }
        precondition(releasedPDF == nil, "Closing the source preview releases its PDF document")
        let searchState = SearchPreviewFixtureState()
        let searchHit = LibraryHit(path: pdfURL.path, folderID: UUID().uuidString, page: 1, excerpt: "Synthetic source evidence.", score: 1)
        var searchHost: NSHostingView<SearchPreviewFixture>? = NSHostingView(rootView: SearchPreviewFixture(state: searchState, hit: searchHit))
        window.setContentSize(CGSize(width: 1000, height: 700)); window.contentView = searchHost
        searchHost?.layoutSubtreeIfNeeded()
        for _ in 0..<100 where searchState.editing.document == nil { try await Task.sleep(for: .milliseconds(25)) }
        weak var searchDocument = searchState.editing.document
        precondition(searchDocument?.page(at: 0)?.string?.contains("Synthetic source evidence.") == true, "Actual Search preview loads searchable PDF content")
        for ask in [true, false, true, false] {
            searchState.ask = ask
            try await Task.sleep(for: .milliseconds(200))
            precondition(searchDocument != nil && searchState.editing.document === searchDocument && !searchState.editing.loading, "Ask preserves the actual Search PDF model and loaded document")
        }
        window.contentView = NSView(); searchHost = nil
        for _ in 0..<20 where searchState.editing.document != nil { try await Task.sleep(for: .milliseconds(25)) }
        precondition(searchState.editing.document == nil, "Leaving Search still releases its PDF")
        window.close()
        project.buffers["main.tex"] = "\\documentclass{article}\n\\begin{document}Synthetic closing check.\\end{document}\n"
        precondition(project.save(), "Synthetic project saves before closing")
        let activeBefore = TeXCache.activeCount
        project.compile()
        for _ in 0..<600 where project.compiling { try await Task.sleep(for: .milliseconds(50)) }
        precondition(!project.compiling && project.pdf != nil, "Closing check has a compiled preview")
        let home = HomeModel(); home.texProject = project
        precondition(home.closeTeX(), "Saved project closes")
        precondition(project.pdf == nil && TeXCache.activeCount == activeBefore, "Closing releases preview and build even while the model is retained")
        project.stop()
        print("Passed native citation popup, acceptance, bibliography preservation, Undo, cache reuse and PDF/session lifetime checks")
        exit(0)
    } catch { print("Citation verification failed:", error); exit(1) }
}
NSApplication.shared.run()
