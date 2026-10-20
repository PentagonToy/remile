import AppKit
import SwiftUI
import PDFKit
import CoreText
import CryptoKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let paperURL = URL(fileURLWithPath: CommandLine.arguments[2])
var finished = false, checks = 0
var failures: [String] = []
_ = NSApplication.shared
@MainActor func verify(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { failures.append(message); print("FAILED: " + message) }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func highlightOpacities(_ document: PDFDocument) -> [String: Double] {
    var values: [String: Double] = [:], array: CGPDFArrayRef?, annotation: CGPDFDictionaryRef?
    guard let page = document.documentRef?.page(at: 1), CGPDFDictionaryGetArray(page.dictionary!, "Annots", &array),
          let array, CGPDFArrayGetDictionary(array, 0, &annotation), let annotation else { return values }
    var opacity: CGPDFReal = 0
    if CGPDFDictionaryGetNumber(annotation, "CA", &opacity) { values["annotation.CA"] = opacity }
    var appearance: CGPDFDictionaryRef?, normal: CGPDFStreamRef?, resources: CGPDFDictionaryRef?, states: CGPDFDictionaryRef?
    if CGPDFDictionaryGetDictionary(annotation, "AP", &appearance), let appearance,
       CGPDFDictionaryGetStream(appearance, "N", &normal), let normal,
       let normalDictionary = CGPDFStreamGetDictionary(normal),
       CGPDFDictionaryGetDictionary(normalDictionary, "Resources", &resources), let resources,
       CGPDFDictionaryGetDictionary(resources, "ExtGState", &states), let states {
        CGPDFDictionaryApplyBlock(states, { name, object, _ in
            var dictionary: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary {
                for key in ["CA", "ca"] {
                    var value: CGPDFReal = 0
                    if CGPDFDictionaryGetNumber(dictionary, key, &value) { values["appearance." + String(cString: name) + "." + key] = value }
                }
            }
            return true
        }, nil)
    }
    return values
}
func fixture(pages: Int = 2, long: Bool = false) -> Data {
    let bytes = NSMutableData()
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &bounds, nil)!
    for number in 1...pages {
        context.beginPDFPage(nil)
        for line in 0..<(long ? 110 : 1) {
            let source = long ? "Page \(number) line \(line). " + String(repeating: "bounded context ", count: 5) : "Page \(number): Physics informed selection and comments."
            let text = NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: long ? 6 : 16)])
            context.textPosition = CGPoint(x: 40, y: 740 - line * 6); CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.endPDFPage()
    }
    context.closePDF(); return bytes as Data
}
@MainActor func until(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    return condition()
}
@MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func rectRecord(_ rect: NSRect) -> [String: Double] { ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height] }
@MainActor func accessibility(_ root: NSView) -> [[String: Any]] {
    var records: [[String: Any]] = [], seen = Set<ObjectIdentifier>()
    func visit(_ value: Any, depth: Int) {
        guard depth < 18, records.count < 1500, let object = value as? NSObject,
              seen.insert(ObjectIdentifier(object)).inserted else { return }
        let info: (label: String, value: String, role: String, screen: NSRect, children: [Any])
        if let element = value as? NSView {
            info = (element.accessibilityLabel() ?? element.accessibilityTitle() ?? "", element.accessibilityValue() as? String ?? "", element.accessibilityRole()?.rawValue ?? "", element.accessibilityFrame(), element.accessibilityChildren() ?? [])
        } else if let element = value as? NSAccessibilityElement {
            info = (element.accessibilityLabel() ?? element.accessibilityTitle() ?? "", element.accessibilityValue() as? String ?? "", element.accessibilityRole()?.rawValue ?? "", element.accessibilityFrame(), element.accessibilityChildren() ?? [])
        } else { return }
        if !info.label.isEmpty || !info.value.isEmpty {
            let screen = info.screen
            let local = root.window.map { root.convert($0.convertFromScreen(screen), from: nil) } ?? screen
            records.append(["role": info.role, "label": info.label, "value": String(info.value.prefix(200)), "frame": rectRecord(screen), "hostFrame": rectRecord(local)])
        }
        for child in info.children { visit(child, depth: depth + 1) }
    }
    visit(root, depth: 0); return records
}
@MainActor func render(_ bytes: Data, sidebar: PDFSession.Sidebar, size: NSSize, dark: Bool, name: String, query: String = "physics") async -> [String: Any] {
    UserDefaults.standard.setVolatileDomain([ReaderAppearance.preference: dark ? "Dark" : "Light", ReaderZoom.preference: 100], forName: UserDefaults.argumentDomain)
    let session = PDFSession(); session.load(bytes); session.showsSidebar = true; session.sidebar = sidebar
    if sidebar == .search { session.query = query }
    if sidebar == .pages { session.twoPage = true; session.firstPageAlone = true }
    let root = PDFWorkspace(data: bytes, session: session, showAsk: true, updateDocument: { _ in preconditionFailure("Snapshot must not change document data") })
        .modifier(ReaderAppearanceModifier()).background(RemileStyle.background)
    let host = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light))
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
    window.orderFront(nil)
    try? await Task.sleep(for: .milliseconds(900))
    _ = await until({ !session.loadingComments && !session.searching })
    host.layoutSubtreeIfNeeded()
    let views = descendants(host), pdfs = views.compactMap { $0 as? PDFSelectionView }
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    let tree = views.map { ["class": NSStringFromClass(type(of: $0)), "frame": rectRecord($0.convert($0.bounds, to: host))] as [String: Any] }
    try! JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + "-views.json"))
    let ax = accessibility(host)
    try! JSONSerialization.data(withJSONObject: ax, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + "-accessibility.json"))
    verify(pdfs.count == 1, "\(name): exact reader selection canvas exists")
    if sidebar == .pages { verify(pdfs[0].displayMode == .twoUpContinuous && pdfs[0].displaysAsBook, "\(name): representable applies native two-page book mode") }
    let canvas = pdfs[0].convert(pdfs[0].bounds, to: host)
    verify(canvas.width >= 379 && canvas.height > 500, "\(name): document keeps a usable reading area")
    verify(host.bounds.insetBy(dx: -1, dy: -1).contains(canvas), "\(name): PDF canvas stays inside workspace")
    let grips = views.filter { $0.identifier?.rawValue == "reader.resize-grip" }.map { $0.convert($0.bounds, to: host) }.sorted { $0.minX < $1.minX }
    verify(grips.count == 2, "\(name): dedicated sidebar and Ask grips exist")
    verify(grips.allSatisfy { abs($0.width - 20) < 1 && abs($0.height - 72) < 1 }, "\(name): only central 20×72 regions expose a resize cursor")
    let columns: [NSRect]
    if grips.count == 2 {
        columns = [NSRect(x: 0, y: canvas.minY, width: grips[0].minX, height: canvas.height), canvas,
                   NSRect(x: grips[1].maxX, y: canvas.minY, width: host.bounds.width - grips[1].maxX, height: canvas.height)]
    } else { columns = [] }
    verify(columns.count == 3, "\(name): sidebar, document and Ask have three readable regions")
    if columns.count == 3 {
        verify(columns[0].width >= 259 && columns[2].width >= 319, "\(name): side panels respect readable minimum widths")
        verify(columns[0].maxX <= columns[1].minX + 1 && columns[1].maxX <= columns[2].minX + 1, "\(name): reading columns do not overlap")
        verify(columns.allSatisfy { host.bounds.insetBy(dx: -1, dy: -1).contains($0) }, "\(name): all split columns stay within the workspace")
        verify(columns.allSatisfy { $0.minY >= 40 }, "\(name): reading header reserves its own space above native columns")
    }
    let text = ax.map { ($0["label"] as? String ?? "") + " " + ($0["value"] as? String ?? "") }.joined(separator: "\n")
    if !ax.isEmpty {
        verify(text.contains("Ask (on-device)"), "\(name): Ask exposes explicit on-device wording")
        verify(!text.contains("Side-bar"), "\(name): sidebar has no broken visible heading")
    }
    if sidebar == .comments { verify(session.comments.isEmpty, "\(name): link descriptions do not become comments") }
    if sidebar == .search { verify(query.isEmpty ? session.matches.isEmpty : !session.matches.isEmpty, "\(name): search results match the supplied query state") }
    let result: [String: Any] = ["name": name, "requested": rectRecord(NSRect(origin: .zero, size: size)), "host": rectRecord(host.bounds), "canvas": rectRecord(canvas), "columns": columns.map(rectRecord), "query": sidebar == .search ? query : "", "matches": session.matches.count, "comments": session.comments.count, "accessibilityAvailable": !ax.isEmpty, "accessibility": ax]
    FileHandle.standardError.write(Data("Rendered \(name): canvas \(canvas.width)×\(canvas.height) at y\(canvas.minY)\n".utf8))
    window.orderOut(nil); window.contentView = nil; session.stop()
    return result
}

Task { @MainActor in
    let paperBytes = try! Data(contentsOf: paperURL, options: .mappedIfSafe), originalDigest = digest(paperBytes)
    verify(PDFDocument(data: paperBytes)?.pageCount == 12, "Read-only paper has the inspected twelve-page structure; its current digest is recorded")
    let paper = PDFDocument(data: paperBytes)!
    verify(paper.pageCount == 12, "Actual paper has twelve pages")
    let allAnnotations = (0..<paper.pageCount).flatMap { paper.page(at: $0)!.annotations }
    let linkCount = allAnnotations.filter { $0.type == "Link" }.count
    verify(linkCount == 219, "Actual paper has 219 document links")
    verify(allAnnotations.filter(PDFSession.isReviewComment).isEmpty, "Actual paper contains zero review comments")
    for type in [PDFAnnotationSubtype.link, .widget, .popup] {
        let item = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 20, height: 20), forType: type, withProperties: nil); item.contents = "Description"
        verify(!PDFSession.isReviewComment(item), "\(type.rawValue) Contents is not a review comment")
    }
    for type in [PDFAnnotationSubtype.text, .freeText, .highlight, .underline, .strikeOut, .ink] {
        let item = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 20, height: 20), forType: type, withProperties: nil); item.contents = "A review note"
        verify(PDFSession.isReviewComment(item), "\(type.rawValue) nonempty review comment accepted")
        item.contents = " \n\t"; verify(!PDFSession.isReviewComment(item), "\(type.rawValue) empty Contents is excluded")
    }
    let actual = PDFSession(); actual.load(paperBytes); actual.loadComments()
    let actualLoaded = await until({ !actual.loadingComments })
    verify(actualLoaded, "Actual comment enumeration completes")
    verify(actual.comments.isEmpty && actual.threads.isEmpty, "Session confirms no spurious publisher or ORCID comments")
    actual.stop()

    let source = fixture(), session = PDFSession(); session.load(source)
    let document = session.document!, page = document.page(at: 0)!
    let view = PDFSelectionView(frame: NSRect(x: 0, y: 0, width: 650, height: 850)); view.document = document; view.layoutDocumentView(); session.attach(view)
    let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
    let selection = page.selection(for: NSRange(location: 8, length: 7))!
    verify(session.select(selection), "Owned selected text enters reader session")
    verify(!session.select(PDFDocument(data: source)!.selectionForEntireDocument!), "Foreign selection cannot replace reader context")
    undo.beginUndoGrouping(); session.highlightSelection(color: .skyBlue); undo.endUndoGrouping()
    let highlight = page.annotations.first { $0.type == "Highlight" }!
    let colour = highlight.color.usingColorSpace(.sRGB)!, expected = HighlightColor.skyBlue.color.usingColorSpace(.sRGB)!
    verify(abs(colour.redComponent - expected.redComponent) < 0.001 && abs(colour.greenComponent - expected.greenComponent) < 0.001 && abs(colour.blueComponent - expected.blueComponent) < 0.001, "Selected context-menu colour reaches native persisted highlight")
    verify(highlight.color.alphaComponent == 0.30, "Selected highlight keeps text readable")
    let pendingHighlightDocument = PDFDocument(data: session.committedData!)!
    let reopenedHighlight = pendingHighlightDocument.page(at: 0)!.annotations.first { $0.type == "Highlight" }!
    let reopenedColour = reopenedHighlight.color.usingColorSpace(.sRGB)!
    let colours = ["expected": [expected.redComponent, expected.greenComponent, expected.blueComponent, 0.30], "reopened": [reopenedColour.redComponent, reopenedColour.greenComponent, reopenedColour.blueComponent, reopenedHighlight.color.alphaComponent]]
    try! JSONSerialization.data(withJSONObject: colours, options: [.prettyPrinted]).write(to: output.appendingPathComponent("highlight-colour.json"))
    let opacities = highlightOpacities(pendingHighlightDocument)
    try! JSONSerialization.data(withJSONObject: opacities, options: [.prettyPrinted]).write(to: output.appendingPathComponent("highlight-opacity.json"))
    try! session.committedData!.write(to: output.appendingPathComponent("colour-highlight.pdf"))
    verify(abs(reopenedColour.blueComponent - expected.blueComponent) < 0.005 && abs(reopenedColour.redComponent - expected.redComponent) < 0.005 && abs(reopenedColour.greenComponent - expected.greenComponent) < 0.005, "Chosen highlight RGB survives pending-byte reopen within one 8-bit step")
    verify(opacities.values.contains { abs($0 - 0.30) < 0.005 }, "Saved highlight appearance or annotation preserves 30 percent opacity")
    undo.undo(); verify(!page.annotations.contains { $0.type == "Highlight" }, "Highlight Undo removes markup")
    undo.redo(); verify(page.annotations.contains { $0.type == "Highlight" }, "Highlight Redo restores markup")
    _ = session.select(selection); session.beginComment(); session.draft = "Synthetic root note"; session.author = "Fixture"
    undo.beginUndoGrouping(); session.saveComment(); undo.endUndoGrouping()
    let ownLoaded = await until({ !session.loadingComments })
    verify(ownLoaded, "Own note loads without a stale task")
    let root = session.comments.first { $0.text == "Synthetic root note" }!
    verify(root.author == "Fixture" && root.pageNumber == 1, "Own note keeps author and source page")
    session.beginReply(root); session.draft = "Synthetic child reply"
    undo.beginUndoGrouping(); session.saveComment(); undo.endUndoGrouping()
    let replyLoaded = await until({ !session.loadingComments })
    verify(replyLoaded, "Reply enumeration completes")
    let thread = session.threads.first { $0.root.text == "Synthetic root note" }!
    verify(thread.replies.map(\.text) == ["Synthetic child reply"], "Own reply stays attached to its parent")
    let reopened = PDFDocument(data: session.committedData!)!
    verify(PDFCommentGraph(document: reopened).parents.count == 1, "Parent relation survives standard PDF reopen")
    let beforeInvalid = session.currentPage
    for number in [Int.min, -1, 0, 3, Int.max] { session.goToPage(number); session.revealLibraryPage(number, terms: []) }
    verify(session.currentPage == beforeInvalid, "Invalid page requests are ignored without overflow or navigation")
    session.goToOutline(PDFDestination(page: PDFDocument(data: source)!.page(at: 0)!, at: .zero))
    verify(session.currentPage == beforeInvalid, "Foreign outline destination is ignored")
    session.twoPage = true; session.firstPageAlone = true
    verify(session.twoPage && session.firstPageAlone, "Session retains two-page layout configuration")
    session.stop()

    let longDocument = PDFDocument(data: fixture(pages: 6, long: true))!
    let context = PDFSelectionContext(selection: longDocument.selectionForEntireDocument, document: longDocument)!
    let passages = context.passages(path: "/synthetic/selection.pdf")
    verify(!passages.isEmpty && passages.count <= 4, "Captured selection caps source-page count")
    verify(passages.allSatisfy { $0.text.count <= 4000 } && passages.reduce(0, { $0 + $1.text.count }) <= 8000, "Captured source context obeys per-page and total budgets")
    verify(passages.allSatisfy { $0.location.unit > 0 && $0.location.path == "/synthetic/selection.pdf" && $0.text.contains("Page \($0.location.unit) line") }, "Each captured passage carries the correct page's text")
    verify(!passages[0].text.contains("Page 2 line"), "Page-two text is never attributed to page one")

    var renders: [[String: Any]] = []
    for dark in [false, true] {
        for (label, size) in [("narrow", NSSize(width: 1000, height: 700)), ("wide", NSSize(width: 1440, height: 900))] {
            renders.append(await render(paperBytes, sidebar: .comments, size: size, dark: dark, name: "pdf-comments-ask-\(label)-\(dark ? "dark" : "light")"))
        }
    }
    for dark in [false, true] {
        for (label, size) in [("narrow", NSSize(width: 1000, height: 700)), ("wide", NSSize(width: 1440, height: 900))] {
            renders.append(await render(paperBytes, sidebar: .search, size: size, dark: dark, name: "pdf-search-ask-\(label)-\(dark ? "dark" : "light")"))
        }
        renders.append(await render(paperBytes, sidebar: .pages, size: NSSize(width: 1440, height: 900), dark: dark, name: "pdf-pages-ask-wide-\(dark ? "dark" : "light")"))
        renders.append(await render(paperBytes, sidebar: .search, size: NSSize(width: 1000, height: 700), dark: dark, name: "pdf-search-empty-ask-narrow-\(dark ? "dark" : "light")", query: ""))
    }
    verify(digest(try! Data(contentsOf: paperURL)) == originalDigest, "Read-only original paper bytes remain unchanged")
    let evidence: [String: Any] = ["checks": checks, "passed": failures.isEmpty, "failures": failures, "paper": ["path": paperURL.path, "sha256": originalDigest, "pages": paper.pageCount, "links": linkCount, "reviewComments": 0], "renders": renders, "limitations": ["Hosted content only: native application toolbar title and installed child-view event delivery not tested", "No Ask generation or translation system UI invoked", "fileURL nil avoids user Ask history; appearance defaults are volatile", "SwiftUI accessibility children may be unavailable in the unbundled interpreter; those labels require visual inspection", "PDFKit remote document layers may be blank in cacheDisplay PNGs; canvas bounds are still measured"]]
    try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("validation.json"))
    print("\(checks) PDF UX integration checks completed; \(failures.count) failures; \(renders.count) exact PDFWorkspace renders; original paper unchanged.")
    finished = true
}
while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
exit(failures.isEmpty ? 0 : 1)
