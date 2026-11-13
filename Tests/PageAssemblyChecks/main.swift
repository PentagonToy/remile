import AppKit
import CoreText
import PDFKit
import SwiftUI
import CryptoKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
func fixture(_ name: String, pages: Int = 3) throws -> Data {
    let font = 3 + pages * 2, link = font + 1, outline = font + 2, section = font + 3, last = 3 + (pages - 1) * 2
    var objects = ["<< /Type /Catalog /Pages 2 0 R /Outlines \(outline) 0 R >>", "<< /Type /Pages /Count \(pages) /Kids [ \((0..<pages).map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")) ] >>"]
    for index in 0..<pages {
        let content = "BT /F1 24 Tf 64 700 Td (\(name) PAGE \(index + 1)) Tj ET"
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(4 + index * 2) 0 R " + (index == 0 ? "/Annots [\(link) 0 R] " : "") + ">>")
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
    }
    objects += ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", "<< /Type /Annot /Sub#74ype /Link /Rect [60 670 210 700] /A << /S /GoTo /D [\(last) 0 R /XYZ 0 700 null] >> >>", "<< /Type /Outlines /First \(section) 0 R /Last \(section) 0 R /Count 1 >>", "<< /Title (\(name) LAST) /Parent \(outline) 0 R /Dest [\(last) 0 R /XYZ 0 700 null] >>"]
    var raw = "%PDF-1.4\n", offsets = [0]
    for (index, object) in objects.enumerated() { offsets.append(raw.utf8.count); raw += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
    let xref = raw.utf8.count
    raw += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() { raw += String(format: "%010d 00000 n \n", offset) }
    raw += "trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n"
    let document = PDFDocument(data: Data(raw.utf8))!, graph = PDFCommentGraph(document: document), page = document.page(at: 0)!
    let root = PDFNotes.make(text: name + " ROOT", author: "Fixture", bounds: CGRect(x: 60, y: 600, width: 24, height: 24))
    _ = try PDFNotes.apply(root, on: page, in: document, adding: true, graph: graph)
    let reply = PDFNotes.make(text: name + " REPLY", author: "Fixture", bounds: root.bounds)
    _ = try PDFNotes.apply(reply, on: page, in: document, adding: true, graph: graph, parent: root)
    let nested = PDFNotes.make(text: name + " NESTED", author: "Fixture", bounds: root.bounds)
    _ = try PDFNotes.apply(nested, on: page, in: document, adding: true, graph: graph, parent: reply)
    return try graph.serialize(document)
}
func texts(_ document: PDFDocument) -> [String] { PDFPageAssembly.pages(document).map { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) } }
func relations(_ document: PDFDocument) -> Int { PDFCommentGraph(document: document).parents.count }
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@MainActor func pageCollection(in view: NSView) -> PageCollectionView? {
    if let collection = view as? PageCollectionView { return collection }
    return view.subviews.lazy.compactMap { pageCollection(in: $0) }.first
}

@MainActor func checkBackgroundOverview() async throws {
    let bytes = try fixture("THUMBNAILS", pages: 24)
    let session = PDFSession()
    session.load(bytes)
    session.showsOverview = true
    func overview(visible: Bool) -> some View {
        PDFWorkspace(data: bytes, session: session, pdfTabVisible: visible, updateDocument: { _ in })
    }
    let host = NSHostingView(rootView: overview(visible: true))
    host.sizingOptions = []
    let frame = CGRect(x: 0, y: 0, width: 760, height: 550)
    let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil; session.stop() }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
    }
    try await settle()
    guard let collection = pageCollection(in: host), let scroll = collection.enclosingScrollView else {
        preconditionFailure("Page overview mounts the native collection")
    }
    func visibleImages() -> Int {
        collection.visibleItems().flatMap { $0.view.subviews }.compactMap { ($0 as? NSImageView)?.image }.count
    }
    let selection: Set<IndexPath> = [IndexPath(item: 11, section: 0)]
    collection.selectionIndexPaths = selection
    collection.actions?.selectionChanged()
    collection.scrollToItems(at: selection, scrollPosition: .centeredVertically)
    try await settle()
    let offset = scroll.contentView.bounds.origin
    let foregroundImages = visibleImages()
    expect(offset.y > 0 && foregroundImages > 0, "Overview renders thumbnails after scrolling")

    host.rootView = overview(visible: false)
    try await settle()
    expect(visibleImages() == 0, "Background overview releases visible thumbnail images")
    expect(pageCollection(in: host) === collection && collection.selectionIndexPaths == selection,
           "Backgrounding preserves the native collection and selection")
    expect(scroll.contentView.bounds.origin == offset, "Backgrounding preserves scroll position")

    host.rootView = overview(visible: true)
    try await settle()
    expect(visibleImages() == foregroundImages, "Returning to the overview restores visible thumbnails")
    expect(pageCollection(in: host) === collection && collection.selectionIndexPaths == selection
           && scroll.contentView.bounds.origin == offset, "Returning preserves selection and scroll position")
    print("Overview thumbnail images on screen: \(foregroundImages) → 0 → \(visibleImages())")
}

Task { @MainActor in
    do {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let original = try fixture("ORIGINAL"), extra = try fixture("INSERTED", pages: 2)
        let sourceURL = output.appendingPathComponent("arrangement.pdf"), insertURL = output.appendingPathComponent("insert.pdf")
        try original.write(to: sourceURL); try extra.write(to: insertURL)
        let session = PDFSession(); session.load(original); session.showsOverview = true
        session.loadComments()
        for _ in 0..<100 where session.loadingComments { try await Task.sleep(for: .milliseconds(10)) }
        let thread = session.threads.first
        expect(session.threads.count == 1 && thread?.root.text == "ORIGINAL ROOT"
               && thread?.replies.map(\.text) == ["ORIGINAL REPLY", "ORIGINAL NESTED"],
               "Reading notes preserves imported reply relationships")
        let nested = thread!.replies[1]
        expect(session.parentComment(of: nested)?.text == "ORIGINAL REPLY",
               "Nested reply cards resolve their immediate parent")
        let replacement = PDFSession(); replacement.load(original); replacement.loadComments()
        for _ in 0..<100 where replacement.loadingComments { try await Task.sleep(for: .milliseconds(10)) }
        let previousNote = replacement.threads[0].replies[1]
        replacement.load(extra)
        expect(replacement.threads.isEmpty && replacement.parentComment(of: previousNote) == nil,
               "Switching documents invalidates thread and parent lookups")
        replacement.loadComments()
        for _ in 0..<100 where replacement.loadingComments { try await Task.sleep(for: .milliseconds(10)) }
        expect(replacement.threads.first?.root.text == "INSERTED ROOT", "The new document builds its own note threads")
        let document = session.document!, pages = PDFPageAssembly.pages(document), undo = UndoManager()
        undo.groupsByEvent = false; session.undoManager = undo
        let token = session.pageDragToken(pages[0])
        undo.beginUndoGrouping(); session.arrangePage(token: token, before: nil); undo.endUndoGrouping()
        expect(session.editingError == nil, "Reorder succeeds")
        expect(texts(document) == ["ORIGINAL PAGE 2", "ORIGINAL PAGE 3", "ORIGINAL PAGE 1"], "First page moves to the end")
        expect(document.page(at: 2) === pages[0], "Reordering retains page identities")
        let moved = PDFDocument(data: session.committedData!)!
        expect(texts(moved) == texts(document) && relations(moved) == 2, "Reopened order and nested replies survive")
        expect(moved.outlineRoot?.child(at: 0)?.destination?.page?.string == pages[2].string, "Original outline retains its target")
        let link = moved.page(at: 2)!.annotations.first { $0.type == "Link" }!
        expect((link.action as? PDFActionGoTo)?.destination.page?.string == pages[2].string, "Original internal link retains its target")
        let changed = session.committedData
        session.arrangePage(token: token, before: pages[1])
        expect(session.committedData == changed && session.editingError != nil, "Stale drag cannot alter new order")
        session.dismissEditingError()
        undo.undo(); expect(texts(document) == ["ORIGINAL PAGE 1", "ORIGINAL PAGE 2", "ORIGINAL PAGE 3"], "Reorder undo")
        undo.redo(); expect(texts(document).last == "ORIGINAL PAGE 1", "Reorder redo")
        undo.beginUndoGrouping(); session.arrangePage(token: session.pageDragToken(pages[2]), before: pages[1]); undo.endUndoGrouping()
        expect(session.editingError == nil && texts(document).first == "ORIGINAL PAGE 3", "A destination page itself can move")
        let destinationMoved = PDFDocument(data: session.committedData!)!
        expect(destinationMoved.outlineRoot?.child(at: 0)?.destination?.page?.string?.contains("ORIGINAL PAGE 3") == true, "Moving destination page preserves outline target")
        undo.undo()
        undo.beginUndoGrouping(); session.insertPDFs([insertURL], before: pages[2]); undo.endUndoGrouping()
        expect(session.editingError == nil && document.pageCount == 5, "PDF insertion succeeds before a target")
        expect(texts(document) == ["ORIGINAL PAGE 2", "INSERTED PAGE 1", "INSERTED PAGE 2", "ORIGINAL PAGE 3", "ORIGINAL PAGE 1"], "Imported file page order is retained")
        let combined = PDFDocument(data: session.committedData!)!
        expect(relations(combined) == 4, "Original and imported nested reply graphs survive")
        let importedLink = combined.page(at: 1)!.annotations.first { $0.type == "Link" }!
        expect((importedLink.action as? PDFActionGoTo)?.destination.page?.string?.contains("INSERTED PAGE 2") == true, "Imported internal link retains its target")
        undo.undo(); expect(document.pageCount == 3 && relations(PDFDocument(data: session.committedData!)!) == 2, "Insertion undo removes only imported pages")
        undo.redo(); expect(document.pageCount == 5 && relations(PDFDocument(data: session.committedData!)!) == 4, "Insertion redo restores page and reply identities")
        expect((try! Data(contentsOf: sourceURL)) == original, "Edits do not autosave")
        let reading = ReadingSession(); try reading.open(sourceURL, recordRecent: false)
        reading.document.content = .pdf(session.committedData!)
        expect(reading.dirty, "Page edit marks canonical document dirty")
        expect(reading.save() && !reading.dirty, "Existing Save commits pending pages")
        expect(texts(PDFDocument(url: sourceURL)!) == texts(document), "Saved file reopens with the final page order")
        expect((try! Data(contentsOf: insertURL)) == extra, "Source of inserted pages remains unchanged")
        let pending = session.committedData
        session.insertPDFs([output.appendingPathComponent("invalid.md")])
        expect(session.committedData == pending && session.editingError != nil, "Invalid external file cannot change the PDF")
        session.dismissEditingError()
        let encrypted = PDFDocument(data: extra)!.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"])!
        let encryptedURL = output.appendingPathComponent("locked.pdf"); try encrypted.write(to: encryptedURL)
        session.insertPDFs([encryptedURL]); expect(session.committedData == pending && session.editingError != nil, "Locked imports do not mutate the document")
        let locked = PDFSession(); locked.load(encrypted)
        expect(!locked.canArrangePages, "Locked document has no page arrangement")
        if CommandLine.arguments.count > 2 {
            let paperURL = URL(fileURLWithPath: CommandLine.arguments[2]), bytes = try Data(contentsOf: paperURL)
            let paper = PDFSession(); paper.load(bytes); let first = paper.document!.page(at: 0)!
            let before = PDFPageAssembly.pages(paper.document!).map { $0.annotations.count }.reduce(0, +)
            paper.arrangePage(token: paper.pageDragToken(first), before: nil)
            expect(paper.editingError == nil && paper.document?.pageCount == 12, "Actual twelve-page paper reorders")
            let reopened = PDFDocument(data: paper.committedData!)!
            expect(PDFPageAssembly.pages(reopened).map { $0.annotations.count }.reduce(0, +) == before, "Actual paper retains all 219 links")
            paper.arrangePage(token: paper.pageDragToken(first), before: paper.document!.page(at: 0))
            expect(paper.editingError == nil && paper.document!.page(at: 0) === first, "Repeated raw-page reorder returns the actual paper to its original order")
            let twice = PDFDocument(data: paper.committedData!)!
            expect(texts(twice) == texts(PDFDocument(data: bytes)!), "All actual paper text survives repeated structural writes")
            expect(digest(try! Data(contentsOf: paperURL)) == digest(bytes), "Actual original paper is unchanged")
        }
        // Leave fresh fixtures for the installed UI checks; their disk bytes have no pending edits.
        try original.write(to: sourceURL)
        for dark in [false, true] {
            let gridSession = PDFSession(); gridSession.load(original); gridSession.showsOverview = true
            let view = PDFWorkspace(data: original, session: gridSession, updateDocument: { _ in }).modifier(ReaderAppearanceModifier())
            let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)); host.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host; host.frame = CGRect(x: 0, y: 0, width: 1100, height: 750)
            window.orderFront(nil); try await Task.sleep(for: .milliseconds(800)); host.layoutSubtreeIfNeeded()
            let firstPage = gridSession.document!.page(at: 0)!
            let revision = "\(gridSession.pageRevision):\(gridSession.pendingAnnotationRevision)"
            let thumbnail = PDFThumbnailCache.shared.image(for: firstPage, size: CGSize(width: 166, height: 204), revision: revision)
            expect(thumbnail != nil, "Overview uses the bounded thumbnail cache")
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(dark ? "overview-dark.png" : "overview-light.png"))
            expect(host.bounds.width == 1100 && host.bounds.height == 750, "Overview respects the requested window bounds")
            window.orderOut(nil); window.contentView = nil; gridSession.stop()
        }
        try await checkBackgroundOverview()
        session.stop(); print("\(checks) page assembly checks passed, including nested replies, internal links, undo, canonical Save and overview renders.")
        exit(0)
    } catch { print("Page assembly checks failed: \(error)"); exit(1) }
}
RunLoop.main.run()
