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

func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
@MainActor func render<V: View>(_ view: V, name: String, size: CGSize, output: URL, check: (NSHostingView<V>) -> Void = { _ in }) async throws {
    let host = NSHostingView(rootView: view); host.sizingOptions = []
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host; host.frame = CGRect(origin: .zero, size: size); window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(900)); host.layoutSubtreeIfNeeded(); check(host)
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    window.orderOut(nil); window.contentView = nil
}
Task { @MainActor in
    do {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let bytes = try fixture("GROUP", pages: 6), session = PDFSession(), undo = UndoManager()
        session.load(bytes); undo.groupsByEvent = false; session.undoManager = undo
        let pages = PDFPageAssembly.pages(session.document!)
        session.selectedOverviewPages = Set([pages[1], pages[3]].map(ObjectIdentifier.init))
        undo.beginUndoGrouping(); session.arrangePages(tokens: [pages[3], pages[1]].map(session.pageDragToken), before: pages[5]); undo.endUndoGrouping()
        expect(session.editingError == nil, "Noncontiguous group move succeeds")
        expect(texts(session.document!) == [1,3,5,2,4,6].map { "GROUP PAGE \($0)" }, "Group retains document order despite pasteboard order")
        expect(session.selectedOverviewPages == Set([pages[1], pages[3]].map(ObjectIdentifier.init)), "Group stays selected")
        expect(relations(PDFDocument(data: session.committedData!)!) == 2, "Group move retains reply graph")
        undo.undo(); expect(texts(session.document!) == (1...6).map { "GROUP PAGE \($0)" }, "One undo restores entire group")
        expect(session.selectedOverviewPages.count == 2, "Undo preserves multiselection")
        undo.redo(); expect(texts(session.document!) == [1,3,5,2,4,6].map { "GROUP PAGE \($0)" }, "Group redo")
        let stale = pages.map(session.pageDragToken)
        undo.beginUndoGrouping(); session.rotateOverviewPages(clockwise: true); undo.endUndoGrouping()
        expect(session.editingError == nil && pages[1].rotation == 90 && pages[3].rotation == 90, "Rotate entire selected group")
        expect(pages[0].rotation == 0, "Unselected page is untouched")
        expect(PDFDocument(data: session.committedData!)!.page(at: 3)!.rotation == 90, "Group rotation persists in bytes")
        let rotated = session.committedData
        session.arrangePages(tokens: [stale[0]], before: nil)
        expect(session.editingError != nil && session.committedData == rotated, "Rotation invalidates stale drag")
        session.dismissEditingError(); undo.undo()
        expect(pages[1].rotation == 0 && pages[3].rotation == 0, "One undo reverses both rotations")
        let beforeSize = session.document!, beforeBytes = session.committedData!
        undo.beginUndoGrouping(); session.fitPages(to: PaperSize.a4.points()); undo.endUndoGrouping()
        expect(session.editingError == nil, "Fit A4 succeeds: \(session.editingError ?? "")")
        let fitted = session.document!
        expect(fitted !== beforeSize, "New vector streams use a new document while old undo objects remain alive")
        expect(texts(fitted) == texts(beforeSize), "All text is preserved by fitting")
        expect(relations(PDFDocument(data: session.committedData!)!) == 2, "Fitting retains nested reply parents")
        expect(abs(fitted.page(at: 0)!.bounds(for: .cropBox).width - PaperSize.a4.points().width) < 0.01, "A4 crop width")
        let destination = (fitted.page(at: 0)?.annotations.first { $0.type == "Link" }?.action as? PDFActionGoTo)?.destination
        expect(destination?.page?.string?.contains("GROUP PAGE 6") == true, "Fitting retains link target")
        expect(fitted.outlineRoot?.child(at: 0)?.destination?.page?.string?.contains("GROUP PAGE 6") == true, "Fitting retains outline target")
        let targetFit = try PDFPageSizing.fitting(crop: beforeSize.page(at: 5)!.bounds(for: .cropBox), rotation: 0, paper: PaperSize.a4.points())
        expect(abs((destination?.point.y ?? -1) - targetFit.point(CGPoint(x: 0, y: 700)).y) < 0.01, "Link destination coordinates are transformed")
        let beforeNote = beforeSize.page(at: 0)!.annotations.first { $0.contents == "GROUP ROOT" }!
        let afterNote = fitted.page(at: 0)!.annotations.first { $0.contents == "GROUP ROOT" }!
        expect(abs(afterNote.bounds.minX - targetFit.rect(beforeNote.bounds).minX) < 0.01, "Comment anchor is transformed")
        expect(session.selectedOverviewPages.count == 2, "Fit maps multiselection to replacement document")
        undo.undo(); expect(session.document === beforeSize && session.committedData == beforeBytes, "Fit undo restores exact prior object and bytes")
        undo.undo(); expect(texts(session.document!) == (1...6).map { "GROUP PAGE \($0)" }, "Undo before fit remains valid")
        undo.redo(); undo.redo(); expect(session.document === fitted, "Redo returns fitted document")
        let noOp = PDFSession(); noOp.load(bytes)
        let group = PDFPageAssembly.pages(noOp.document!)
        noOp.arrangePages(tokens: [group[1], group[2]].map(noOp.pageDragToken), before: group[2])
        expect(noOp.committedData == nil && noOp.editingError == nil, "Drop inside a contiguous group is a no-op")
        noOp.arrangePages(tokens: group.map(noOp.pageDragToken), before: nil)
        expect(noOp.committedData == nil, "Dragging all pages to the end is a no-op")
        let namedFile = try PDFReplyWriter.File(bytes), namedPages = try namedFile.pages()
        let root = namedFile.trailer["Root"]!.reference!, last = namedPages.last!
        let dest = "[ \(last.object) \(last.generation) R /XYZ 0 700 null ]"
        let namedBytes = try PDFReplyWriter.replacingDictionaries(namedFile, patches: [root: ["Dests": "<< /chapter \(dest) >>", "Names": "<< /Dests << /Names [ (chapter) \(dest) ] >> >>"]])
        let named = PDFSession(); named.load(namedBytes); named.fitPages(to: PaperSize.a4.points())
        expect(named.editingError == nil, "Direct legacy and name-tree destinations fit")
        let finalFile = try PDFReplyWriter.File(named.committedData!), finalRoot = try finalFile.object(root)
        let legacy = finalRoot["Dests"]!["chapter"]!.array!
        let modern = finalRoot["Names"]!["Dests"]!["Names"]!.array![1].array!
        expect(abs(legacy[3].number! - Double(targetFit.point(CGPoint(x: 0, y: 700)).y)) < 0.01, "Legacy destination coordinate fits")
        expect(abs(modern[3].number! - legacy[3].number!) < 0.01, "Inline name-tree destination coordinate fits")
        for rotation in [0,90,180,270] {
            let crop = CGRect(x: -40, y: 80, width: 900, height: 430)
            let fit = try PDFPageSizing.fitting(crop: crop, rotation: rotation, paper: PaperSize.a3.points())
            expect(fit.box.insetBy(dx: -0.001, dy: -0.001).contains(fit.rect(crop)), "Rotated nonzero crop remains within paper")
            expect(abs(fit.rect(crop).midX - fit.box.midX) < 0.001 && abs(fit.rect(crop).midY - fit.box.midY) < 0.001, "Fit is centred")
        }
        expect(PaperSize.b4ISO.millimetres != PaperSize.b4JIS.millimetres, "B4 standards are distinct")
        let now = Date(timeIntervalSince1970: 1792400000), calendar = Calendar(identifier: .gregorian)
        expect(RecentReadingRow.relativeDate(now, now: now, calendar: calendar) == "Today", "True opened date: Today")
        expect(RecentReadingRow.relativeDate(calendar.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: calendar) == "Yesterday", "True opened date: Yesterday")
        typealias Split = ReaderSplit<Text,Text>
        expect(Split.handleWidth == 20, "Grip target is wide")
        expect(Split.constrained(400, available: 1000, minimum: 260, maximum: 440, content: 720) == 260, "Grip protects reading space")
        expect(Split.constrained(900, available: 1440, minimum: 260, maximum: 440, content: 720) == 440, "Grip caps pane width")
        if CommandLine.arguments.count > 2 {
            let url = URL(fileURLWithPath: CommandLine.arguments[2]), original = try Data(contentsOf: url)
            let paper = PDFSession(); paper.load(original)
            let all = PDFPageAssembly.pages(paper.document!)
            paper.selectedOverviewPages = Set(all.prefix(3).map(ObjectIdentifier.init))
            paper.arrangePages(tokens: all.prefix(3).map(paper.pageDragToken), before: nil)
            expect(paper.editingError == nil, "Real tagged paper bulk reorder")
            paper.rotateOverviewPages(clockwise: true)
            expect(paper.editingError == nil, "Raw rotation after reorder preserves tagged text")
            let text = texts(paper.document!)
            paper.fitPages(to: PaperSize.a4.points())
            expect(paper.editingError == nil, "Actual tagged paper fits: \(paper.editingError ?? "")")
            expect(texts(paper.document!) == text, "Real tagged text survives reorder, rotation and fit")
            let check = PDFDocument(data: paper.committedData!)!
            expect(PDFPageAssembly.pages(check).reduce(0) { $0 + $1.annotations.filter { $0.type == "Link" }.count } == 219, "All 219 real links survive")
            try paper.committedData!.write(to: output.appendingPathComponent("fitted-paper.pdf"))
            let target = PaperSize.a4.points()
            expect(PDFPageAssembly.pages(check).allSatisfy { page in
                let crop = page.bounds(for: .cropBox), sideways = page.rotation % 180 != 0
                return abs((sideways ? crop.height : crop.width) - target.width) < 0.01 && abs((sideways ? crop.width : crop.height) - target.height) < 0.01
            }, "All mixed-rotation pages have the same displayed A4 size")
            for index in [0, check.pageCount - 1] {
                let image = check.page(at: index)!.thumbnail(of: CGSize(width: 700, height: 1000), for: .cropBox)
                if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("fitted-page-\(index).png"))
                }
            }
            expect(try! Data(contentsOf: url) == original, "User paper remains unchanged")
        }
        for dark in [false,true] {
            let scheme: ColorScheme = dark ? .dark : .light
            UserDefaults.standard.setVolatileDomain([ReaderAppearance.preference: dark ? "Dark" : "Light"], forName: UserDefaults.argumentDomain)
            for width in [1000.0,1440.0] {
                let grid = PDFSession(); grid.load(bytes); grid.showsOverview = true
                grid.selectedOverviewPages = Set(PDFPageAssembly.pages(grid.document!).prefix(3).map(ObjectIdentifier.init))
                try await render(PDFThumbnailOverview(session: grid).modifier(ReaderAppearanceModifier()).environment(\.colorScheme, scheme), name: "grid-\(Int(width))-\(dark)", size: CGSize(width: width, height: 720), output: output) { host in
                    let collections = descendants(host).compactMap { $0 as? NSCollectionView }
                    expect(collections.count == 1, "Native collection exists")
                    if let collection = collections.first {
                        expect(collection.allowsMultipleSelection && collection.numberOfItems(inSection: 0) == 6, "Native multi-selection and page count")
                        expect(collection.selectionIndexPaths.count == 3, "Native group selection matches session")
                        expect(host.bounds.contains(collection.enclosingScrollView!.convert(collection.enclosingScrollView!.bounds, to: host)), "Grid stays inside window")
                    }
                }
            }
            try await render(ReaderSettings().modifier(ReaderAppearanceModifier()).environment(\.colorScheme, scheme), name: "settings-\(dark)", size: CGSize(width: 720, height: 560), output: output)
            let home = HomeModel()
            let sample = output.appendingPathComponent("A recent document.pdf"); try bytes.write(to: sample)
            let markdown = output.appendingPathComponent("Research notes.md"); try "# Research notes".write(to: markdown, atomically: true, encoding: .utf8)
            home.recent = [sample, markdown]
            expect(RemileArtwork.image("banner", dark: dark) != nil, "Authored banner loads in source harness")
            try await render(HomeWorkspace(model: home, loadOnAppear: false).modifier(ReaderAppearanceModifier()).environment(\.colorScheme, scheme), name: "home-\(dark)", size: CGSize(width: 1200, height: 900), output: output)
        }
        print("\(checks) interaction checks passed"); exit(0)
    } catch { print("Interaction checks failed: \(error)"); exit(1) }
}
RunLoop.main.run()
