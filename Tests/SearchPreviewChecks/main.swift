import CoreText

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw NSError(domain: "SearchPreviewChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    checks += 1
}
func fixture(_ url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for text in ["Alpha beta café alpha", "Second page gamma"] {
        context.beginPDFPage(nil); context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16)])), context)
        context.endPDFPage()
    }
    context.closePDF()
}
@MainActor
func settle(_ model: SearchPDFModel) async throws {
    for _ in 0..<200 { if !model.loading { return }; try await Task.sleep(for: .milliseconds(10)) }
    throw NSError(domain: "Search preview timed out", code: 2)
}
@MainActor
func runChecks() async throws {
    let url = output.appendingPathComponent("preview-fixture.pdf")
    fixture(url); let original = try Data(contentsOf: url)
    let document = PDFDocument(url: url)!, page = document.page(at: 0)!
    let phrases = try LibraryIndex.queryTerms("\"alpha beta\" café")
    try check(phrases == ["alpha beta", "café"], "Index and preview share phrase parsing")
    try check(SearchPDFCanvas.selections(on: page, query: "\"alpha beta\"").count == 1, "Quoted phrase highlights as one selection")
    try check(SearchPDFCanvas.selections(on: page, query: "ALPHA").count == 2, "Case-insensitive occurrences are highlighted")
    try check(SearchPDFCanvas.selections(on: page, query: "cafe").count == 1, "Accent-insensitive highlight agrees with the index")
    try check(SearchPDFCanvas.selections(on: document.page(at: 1)!, query: "alpha").isEmpty, "Highlights stay on the selected result page")
    try check(SearchPDFCanvas.selections(on: page, query: "\"").isEmpty, "Malformed query produces no stale highlights")
    try check(page.annotations.isEmpty, "Highlights never add PDF annotations")
    let groupHits = [
        LibraryHit(path: "/library/One.pdf", folderID: "a", page: 3, excerpt: "First", score: -3),
        LibraryHit(path: "/library/Two.pdf", folderID: "a", page: 1, excerpt: "Second", score: -2),
        LibraryHit(path: "/library/One.pdf", folderID: "a", page: 7, excerpt: "Third", score: -1)
    ]
    let groups = SearchResultGroup.make(groupHits)
    try check(groups.map(\.path) == ["/library/One.pdf", "/library/Two.pdf"], "Document groups follow their best global result")
    try check(groups[0].hits.map(\.page) == [3, 7], "A document retains its ranked page order")
    try check(groups.map(\.bestRank) == [1, 2], "Grouping retains global rank provenance")
    try check(SearchResultGroup.make(groupHits, filter: "tWo").map(\.path) == ["/library/Two.pdf"], "Document filtering is case-insensitive")
    try check(SearchResultGroup.make(groupHits, filter: "missing").isEmpty, "A document filter does not invent results")
    try check(SearchResultGroup.make([]).isEmpty, "Empty searches have no groups")
    let interleaved = [
        LibraryHit(path: "/library/A.pdf", folderID: "a", page: 80, excerpt: "best", score: -4),
        LibraryHit(path: "/library/B.pdf", folderID: "a", page: 2, excerpt: "second", score: -3),
        LibraryHit(path: "/library/B.pdf", folderID: "a", page: 4, excerpt: "third", score: -2),
        LibraryHit(path: "/library/A.pdf", folderID: "a", page: 1, excerpt: "fourth", score: -1)
    ]
    let relevance = SearchResultGroup.make(interleaved)
    try check(relevance.map(\.bestRank) == [1, 2] && relevance[0].hits.map(\.page) == [80, 1], "Documents use their strongest global match and child rows default to relevance")
    try check(relevance[0].rank(for: relevance[0].hits[1]) == 4 && relevance[1].rank(for: relevance[1].hits[0]) == 2, "A lower result in the first document may rank below a result in another document")
    let rankOrder = RankedSearchHit.make(interleaved)
    try check(rankOrder.map(\.hit.id) == interleaved.map(\.id) && rankOrder.map(\.rank) == [1, 2, 3, 4], "Rank view interleaves documents in the engine's global order")
    try check(RankedSearchHit.make(interleaved, filter: "B.pdf").map(\.rank) == [2, 3], "Filtering flat results preserves original ranks")
    try check(RankedSearchHit.make([], filter: " ").isEmpty, "Empty rank view is safe")
    let filteredRank = SearchResultGroup.make(interleaved, filter: "B.pdf")
    try check(filteredRank[0].bestRank == 2, "Filtering documents does not silently renumber global matches")
    let hit = LibraryHit(path: url.path, folderID: "fixture", page: 1, excerpt: "alpha", score: -1)
    let model = SearchPDFModel(); model.show(hit); try await settle(model)
    try check(model.document?.pageCount == 2 && model.error == nil, "PDF loads away from the main actor")
    let cached = model.document
    model.show(LibraryHit(path: url.path, folderID: "fixture", page: 2, excerpt: "gamma", score: -1))
    try check(model.document === cached && !model.loading, "Moving within the same document reuses its PDF")
    model.show(hit, revision: UUID()); try await settle(model)
    try check(model.document !== cached && model.error == nil, "Index refresh invalidates the cached PDF snapshot")
    let missing = LibraryHit(path: output.appendingPathComponent("missing.pdf").path, folderID: "fixture", page: 1, excerpt: "", score: -1)
    model.show(missing); model.show(hit); try await settle(model)
    try check(model.document != nil && model.error == nil, "Superseded missing-file load cannot replace the current result")
    model.show(nil)
    try check(model.document == nil && !model.loading, "Clearing results releases the preview")
    model.show(missing); try await settle(model)
    try check(model.error != nil && model.document == nil, "Unavailable files show an error")
    model.show(hit); model.close(); try await Task.sleep(for: .milliseconds(100))
    try check(model.document == nil && model.error == nil && !model.loading, "Closing discards an in-flight PDF load")
    let after = try Data(contentsOf: url)
    try check(after == original, "Preview and highlights leave source bytes untouched")
    let thumbnail = try await SearchCoverStore.shared.image(path: url.path, revision: UUID())
    try check(thumbnail.flatMap(NSImage.init(data:)) != nil, "PDF cover is decoded from its real first page")
    let absentCover = try await SearchCoverStore.shared.image(path: missing.path, revision: UUID())
    try check(absentCover == nil, "Unavailable thumbnails retain a safe placeholder")
    let overlay = HighlightOverlay(pdfView: PDFView(), page: page, query: "alpha")
    try check(overlay.hitTest(.zero) == nil, "Highlight overlays never intercept document interaction")
    try check(SearchPDFCanvas.selections(on: page, query: "alph").isEmpty, "PDF highlights do not mark partial words")
    try check(SearchMarkdown.searchText("# Heading\n\n**Alpha** beta.").contains("Heading\nAlpha beta."), "Markdown blocks retain word boundaries in the search index")
    let annotationURL = output.appendingPathComponent("annotation-fixture.pdf")
    try original.write(to: annotationURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: annotationURL.path)
    let store = PDFHighlightStore(), region = HighlightRegion(page: 0, bounds: page.selection(for: NSRange(location: 0, length: 5))!.bounds(for: page), text: "Alpha")
    var last = original
    for color in HighlightColor.allCases {
        let saved = try await store.add(url: annotationURL, expected: PDFHighlightStore.digest(last), regions: [region], color: color)
        let data = try Data(contentsOf: annotationURL), reopened = PDFDocument(data: data)!
        let mark = reopened.page(at: 0)!.annotations.last!
        let actual = mark.color.usingColorSpace(.deviceRGB)!, expected = color.color.usingColorSpace(.deviceRGB)!
        try check(mark.type == "Highlight" && mark.quadrilateralPoints?.count == 4, "\(color.name) saves standard text markup and quadrilaterals")
        try check(abs(actual.redComponent - expected.redComponent) < 0.005 && abs(actual.greenComponent - expected.greenComponent) < 0.005 && abs(actual.blueComponent - expected.blueComponent) < 0.005, "\(color.name) preserves its Okabe–Ito RGB components")
        try check(reopened.page(at: 0)!.string == page.string && reopened.pageCount == 2, "\(color.name) preserves original PDF text and pages")
        try check(saved.digest == PDFHighlightStore.digest(data), "\(color.name) commits the expected source revision")
        last = data
    }
    try check(Set(HighlightColor.allCases.map(\.hex)).count == 8, "Only the eight fixed palette colours are exposed")
    let permissions = try FileManager.default.attributesOfItem(atPath: annotationURL.path)[.posixPermissions] as? Int
    try check(permissions == 0o640, "Highlight saving preserves file permissions")
    let edited = last
    try Data("External edit".utf8).write(to: annotationURL)
    var rejected = false
    do { _ = try await store.add(url: annotationURL, expected: PDFHighlightStore.digest(last), regions: [region], color: .yellow) } catch { rejected = true }
    let external = try Data(contentsOf: annotationURL)
    try check(rejected && external == Data("External edit".utf8), "External edits are never overwritten")
    try edited.write(to: annotationURL)
    _ = try await store.restore(url: annotationURL, expected: PDFHighlightStore.digest(edited), data: original)
    let restored = try Data(contentsOf: annotationURL)
    try check(restored == original, "Undo restores the exact pre-highlight bytes")
    var invalidRegion = false
    do { _ = try await store.add(url: annotationURL, expected: PDFHighlightStore.digest(original), regions: [HighlightRegion(page: 0, bounds: CGRect(x: -999, y: 0, width: 10, height: 10), text: "invalid")], color: .blue) } catch { invalidRegion = true }
    try check(invalidRegion && (try? Data(contentsOf: annotationURL)) == original, "Invalid geometry cannot alter the source")
    let editableHit = LibraryHit(path: annotationURL.path, folderID: "fixture", page: 1, excerpt: "Alpha", score: -1)
    let editor = SearchPDFModel(); editor.show(editableHit); try await settle(editor)
    let editView = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    editView.document = editor.document; editor.attach(editView)
    editView.setCurrentSelection(editor.document!.page(at: 0)!.selection(for: NSRange(location: 0, length: 5)), animate: false)
    editor.color = .skyBlue; editor.highlight()
    for _ in 0..<300 { if !editor.saving { break }; try await Task.sleep(for: .milliseconds(10)) }
    try check(editor.canUndoHighlight && editor.editMessage == nil && editor.document?.page(at: 0)?.annotations.count == 1, "Search preview selection writes a real highlight and enables Undo")
    try Data(contentsOf: annotationURL).write(to: output.appendingPathComponent("visible-highlight.pdf"))
    editor.undoHighlight()
    for _ in 0..<300 { if !editor.saving { break }; try await Task.sleep(for: .milliseconds(10)) }
    try check(!editor.canUndoHighlight && (try? Data(contentsOf: annotationURL)) == original, "Search preview Undo restores the original file")
    editView.document = editor.document
    editView.setCurrentSelection(editor.document!.page(at: 0)!.selection(for: NSRange(location: 0, length: 5)), animate: false)
    let openDocument = NSDocument(); openDocument.fileURL = annotationURL; NSDocumentController.shared.addDocument(openDocument)
    editor.highlight()
    try check(!editor.saving && editor.editMessage != nil && (try? Data(contentsOf: annotationURL)) == original, "A PDF open in the reader cannot be overwritten from Search")
    NSDocumentController.shared.removeDocument(openDocument)
    let form = PDFDocument(data: original)!, widget = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 100, height: 30), forType: .widget, withProperties: nil)
    widget.fieldName = "Fixture"; form.page(at: 0)!.addAnnotation(widget)
    let formBytes = form.dataRepresentation()!, formURL = output.appendingPathComponent("form-fixture.pdf")
    try formBytes.write(to: formURL)
    let formHighlight = try await store.add(url: formURL, expected: PDFHighlightStore.digest(formBytes), regions: [region], color: .yellow)
    try check(formHighlight.document.page(at: 0)!.annotations.contains { $0.type == "Widget" && $0.fieldName == "Fixture" }, "Highlighting preserves the existing widget")
    try check(formHighlight.document.page(at: 0)!.annotations.contains { $0.type == "Highlight" }, "A form PDF can receive a standard highlight")
    _ = try await store.restore(url: formURL, expected: formHighlight.digest, data: formHighlight.previous)
    try check((try? Data(contentsOf: formURL)) == formBytes, "Form highlight undo restores the same file bytes")
    editor.close()
    let signedFixtures = output.deletingLastPathComponent().appendingPathComponent("fixtures")
    for permission in [1, 3] {
        let source = try Data(contentsOf: signedFixtures.appendingPathComponent("signed-p\(permission).pdf"))
        let signedURL = output.appendingPathComponent("signed-search-p\(permission).pdf")
        try source.write(to: signedURL)
        let signed = SearchPDFModel()
        signed.show(LibraryHit(path: signedURL.path, folderID: "fixture", page: 1, excerpt: "Signed", score: -1)); try await settle(signed)
        let signedView = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        signedView.document = signed.document; signed.attach(signedView)
        signedView.setCurrentSelection(signed.document!.selectionForEntireDocument, animate: false)
        signed.highlight()
        try check(signed.protection.isLocked && signed.protection.attempts == 1 && !signed.hasPendingEdits, "Signed Search refuses edits until consent")
        try signed.protection.authorise(data: source)
        let backup = signed.protection.snapshotURL!
        signed.highlight()
        try check(signed.hasPendingEdits && (try? Data(contentsOf: signedURL)) == source, "Unlocked Search stages changes without writing the source")
        signedView.setCurrentSelection(signed.document!.selectionForEntireDocument, animate: false)
        signed.highlight()
        try check(signed.protection.snapshotURL == backup && (try? Data(contentsOf: backup)) == source, "Multiple edits share one temporary original")
        signed.undoHighlight()
        try check(signed.hasPendingEdits, "Undo removes only the last staged highlight")
        try check(signed.saveChanges() && !signed.hasPendingEdits && signed.protection.snapshotURL == nil && !FileManager.default.fileExists(atPath: backup.path), "Save commits and removes the temporary original")
        let saved = try Data(contentsOf: signedURL)
        if permission == 3 { try check(saved.starts(with: source), "Permitted Search highlight retains the signed byte prefix") }
        signedView.document = signed.document
        signedView.setCurrentSelection(signed.document!.selectionForEntireDocument, animate: false)
        signed.highlight()
        try check(signed.hasPendingEdits, "Later changes create a new staged transaction")
        signed.discardChanges()
        try check(!signed.hasPendingEdits && signed.protection.isLocked && signed.protection.snapshotURL == nil && (try? Data(contentsOf: signedURL)) == saved, "Discard restores the last Save and removes the backup")
        signed.close()
    }
    print("Passed \(checks) search preview checks")
}
Task<Void, Never> {
    do { try await runChecks(); exit(0) }
    catch { print("FAILED: \(error)"); exit(1) }
}
app.run()
