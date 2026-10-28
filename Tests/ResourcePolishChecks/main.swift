import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
var passed = 0
func check(_ value: Bool, _ label: String) { precondition(value, label); passed += 1; print("PASS: " + label) }
@MainActor func until(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !ready() { precondition(ContinuousClock.now < deadline, "Fixture did not finish"); try await Task.sleep(for: .milliseconds(10)) }
}
let output = URL(fileURLWithPath: CommandLine.arguments[1]), app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        let fm = FileManager.default; try fm.createDirectory(at: output, withIntermediateDirectories: true)
        check(SourceDigest.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 preserves the automation protocol vector")
        check(SourceDigest.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "Empty-source SHA-256 stays compatible")
        let markdown = MarkdownPreviewModel(), markdownURL = output.appendingPathComponent("source.md")
        var htmlUpdates = 0
        let htmlObserver = markdown.$html.dropFirst().sink { _ in htmlUpdates += 1 }
        await markdown.render("# Stable preview\nSame content.", url: markdownURL)
        let stableHTML = markdown.html
        await markdown.render("# Stable preview\nSame content.", url: markdownURL)
        check(markdown.html == stableHTML && htmlUpdates == 1, "Unchanged Markdown reuses its successful preview without republishing HTML")
        await markdown.render("# Stable preview\nSame content.", url: output.appendingPathComponent("other/source.md"))
        check(htmlUpdates == 2, "A different Markdown base URL still rerenders relative resources")
        htmlObserver.cancel()
        let outlineSources = ["main.tex": "\\section{Main}\n%\\input{absent}\n\\input{part}\n", "part.tex": "\\subsection{Detail}\n"]
        check(TeXOutlineItem.project(outlineSources, main: "main.tex").map(\.title) == ["Main", "Detail"], "Reused outline patterns preserve include order and ignored comments")
        let cancelledOutline = Task.detached {
            do { try await Task.sleep(for: .seconds(30)) } catch { }
            return TeXOutlineItem.project(outlineSources, main: "main.tex")
        }
        cancelledOutline.cancel()
        check(await cancelledOutline.value.isEmpty, "Cancelled LaTeX outline work stops without publishing stale headings")
        let thumbDocument = PDFDocument()
        for number in 1...4 {
            let image = NSImage(size: NSSize(width: 240, height: 320))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 240, height: 320).fill()
            ("A page to read\n\nSection \(number)\n\nA quiet space for notes." as NSString).draw(in: NSRect(x: 20, y: 30, width: 200, height: 260), withAttributes: [.foregroundColor: NSColor.black, .font: NSFont.systemFont(ofSize: 14)])
            image.unlockFocus()
            thumbDocument.insert(PDFPage(image: image)!, at: number - 1)
        }
        for dark in [false, true] {
            let panel = NSHostingView(rootView: PDFPagesPanel(document: thumbDocument, currentPage: 2, select: { _ in }).environment(\.colorScheme, dark ? .dark : .light).foregroundStyle(RemileStyle.ink).background(RemileStyle.sidebar).frame(width: 240, height: 720))
            panel.frame = NSRect(x: 0, y: 0, width: 240, height: 720); panel.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
            if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                panel.cacheDisplay(in: panel.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("pdf-pages-" + (dark ? "dark" : "light") + ".png"))
            }
        }
        let selectionSession = PDFSession()
        selectionSession.load(pdfImageFixture(rotation: 0))
        let selectionView = PDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        selectionView.document = selectionSession.document; selectionSession.attach(selectionView)
        let selectionPage = selectionSession.document!.page(at: 0)!
        var selectionUpdates = 0
        let selectionObserver = selectionSession.objectWillChange.sink { selectionUpdates += 1 }
        selectionView.setCurrentSelection(selectionPage.selection(for: NSRange(location: 0, length: 6)), animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: selectionView)
        check(selectionSession.canHighlight, "A text selection still enables Highlight")
        let firstSelectionUpdates = selectionUpdates
        for _ in 0..<100 { NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: selectionView) }
        check(selectionUpdates == firstSelectionUpdates, "Repeated valid selection notifications do not republish the workspace")
        selectionView.setCurrentSelection(selectionPage.selection(for: NSRange(location: 7, length: 5)), animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: selectionView)
        check(selectionUpdates == firstSelectionUpdates && selectionSession.assistantSelection?.text == "title", "Actions read the current selection without requiring a workspace refresh")
        selectionView.clearSelection(); NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: selectionView)
        check(!selectionSession.canHighlight && selectionUpdates == firstSelectionUpdates + 1, "Clearing a selection updates toolbar availability once")
        let pageUpdates = selectionUpdates
        for _ in 0..<50 { NotificationCenter.default.post(name: .PDFViewPageChanged, object: selectionView) }
        check(selectionUpdates == pageUpdates, "Repeated notifications for the current page do not republish navigation")
        selectionObserver.cancel(); selectionSession.stop()
        let reference = ReferenceRecord(fields: ["title": "A concise reference", "author": "Writer, Example", "year": "2026", "abstract": "This abstract remains visible while BibTeX export omits it. It explains the method and its limits without a generated summary."])
        let referenceModel = ReferenceModel(repository: ReferenceRepository(root: output.appendingPathComponent("reference-preview")))
        for dark in [false, true] {
            let preview = NSHostingView(rootView: ReferencePreview(record: reference, model: referenceModel, openPDF: { _, _ in }, addFiles: {}).environment(\.colorScheme, dark ? .dark : .light).foregroundStyle(RemileStyle.ink).frame(width: 320, height: 720))
            preview.frame = NSRect(x: 0, y: 0, width: 320, height: 720); preview.layoutSubtreeIfNeeded()
            if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(dark ? "reference-abstract-dark.png" : "reference-abstract-light.png"))
            }
        }
        let watched = output.appendingPathComponent("mailbox"); try fm.createDirectory(at: watched, withIntermediateDirectories: true)
        let changes = try DirectoryChanges(watched); var events = 0
        let reader = Task { @MainActor in for await _ in changes.events { events += 1 } }
        try await until { events == 1 }; try await Task.sleep(for: .milliseconds(150))
        check(events == 1, "The mailbox has no timer-generated events while idle")
        try Data("queued".utf8).write(to: watched.appendingPathComponent("request"), options: .atomic)
        try await until { events > 1 }; check(events > 1, "Atomic publication wakes the directory reader")
        changes.cancel(); await reader.value
        var ended = false
        let replacement = try DirectoryChanges(watched)
        let renames = Task { @MainActor in for await _ in replacement.events {}; ended = true }
        try fm.moveItem(at: watched, to: output.appendingPathComponent("renamed-mailbox")); try await until { ended }
        check(ended, "A replaced mailbox ends its watcher so the server can reattach")
        replacement.cancel(); await renames.value
        let root = output.appendingPathComponent("project"); try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = "\\documentclass{article}\n\\begin{document}\n" + String(repeating: "% source context\n", count: 10000) + "\\end{document}\n"
        try source.write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try "\\section{Linked}\nText\n".write(to: root.appendingPathComponent("part.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        check(project.cachedSourceHashCount == 0, "Opening a project does not eagerly hash every buffer")
        let first = project.sourceHashes
        check(project.cachedSourceHashCount == 2, "The first reader caches one digest per source")
        check((0..<30).allSatisfy { _ in project.sourceHashes == first }, "Repeated readers preserve the same source identity")
        project.buffers["main.tex"]! += "% changed\n"
        check(project.cachedSourceHashCount == 1, "An edit invalidates only its own digest")
        let second = project.sourceHashes
        check(second["main.tex"] != first["main.tex"] && second["part.tex"] == first["part.tex"], "Review and CLI see the edited version and the unchanged neighbour")
        project.buffers.removeValue(forKey: "part.tex")
        check(project.sourceHashes["part.tex"] == nil, "Deleted files do not retain cached fingerprints")
        check(!project.save(), "A missing source buffer fails safely before saving any file")
        check(try String(contentsOf: root.appendingPathComponent("main.tex"), encoding: .utf8) == source, "A missing buffer cannot cause a partial save")
        // Restore the partial fixture mutation before the autosave task runs.
        project.buffers["part.tex"] = try String(contentsOf: root.appendingPathComponent("part.tex"), encoding: .utf8)
        let home = HomeModel(index: LibraryIndex(location: output.appendingPathComponent("library.sqlite")), overleaf: OverleafLibrary(directory: output.appendingPathComponent("Overleaf")))
        home.texProject = project
        let transport = output.appendingPathComponent("transport")
        try fm.createDirectory(at: transport, withIntermediateDirectories: true)
        var ready: HomeModel?
        var homeLookups = 0
        let queued = EditorBridge.Request(operation: "status")
        func publish(_ request: EditorBridge.Request) throws -> URL {
            let url = transport.appendingPathComponent(request.id.uuidString + ".request.json")
            try JSONEncoder().encode(request).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); return url
        }
        _ = try publish(queued)
        let service = Task { @MainActor in await EditorBridge.serve({ homeLookups += 1; return ready }, directory: transport) }
        let response = transport.appendingPathComponent(queued.id.uuidString + ".response.json")
        try await Task.sleep(for: .milliseconds(80)); ready = home
        try await until { fm.fileExists(atPath: response.path) }
        check(try (JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any])?["ok"] as? Bool == true, "Queued CLI requests survive watcher attachment and window registration")
        var duplicate = EditorBridge.Request(operation: "rename", file: "main.tex"); duplicate.id = queued.id; duplicate.name = "unexpected.tex"
        let duplicateFile = try publish(duplicate); try await until { !fm.fileExists(atPath: duplicateFile.path) }
        check(project.main == "main.tex" && fm.fileExists(atPath: root.appendingPathComponent("main.tex").path), "An existing response prevents duplicate mutation execution")
        let malformed = transport.appendingPathComponent(UUID().uuidString + ".request.json")
        try Data("not-json".utf8).write(to: malformed, options: .atomic)
        let burst = (0..<25).map { _ in EditorBridge.Request(operation: "status") }
        for request in burst { _ = try publish(request) }
        try await until { burst.allSatisfy { fm.fileExists(atPath: transport.appendingPathComponent($0.id.uuidString + ".response.json").path) } }
        try await until { !fm.fileExists(atPath: malformed.path) }
        check(!fm.fileExists(atPath: malformed.path), "Malformed owned requests cannot starve a burst of valid commands")
        let malformedReply = transport.appendingPathComponent(malformed.lastPathComponent.replacingOccurrences(of: ".request.json", with: ".response.json"))
        check(try (JSONSerialization.jsonObject(with: Data(contentsOf: malformedReply)) as? [String: Any])?["ok"] as? Bool == false, "Malformed requests receive a correlated error instead of a CLI timeout")
        check(burst.count == 25, "A coalesced directory event drains more than one request batch")
        var resourceRequest = EditorBridge.Request(operation: "diagnostics"); resourceRequest.id = UUID()
        _ = try publish(resourceRequest)
        let diagnosticResponse = transport.appendingPathComponent(resourceRequest.id.uuidString + ".response.json")
        try await until { fm.fileExists(atPath: diagnosticResponse.path) }
        let diagnosticJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: diagnosticResponse)) as! [String: Any]
        check(diagnosticJSON["ok"] as? Bool == true && (diagnosticJSON["memory"] as? [String: Any])?["scope"] as? String == "mainProcessOnly", "The actual mailbox exposes scoped resource diagnostics")
        ready = nil
        let abandoned = EditorBridge.Request(operation: "status")
        let previousLookups = homeLookups
        let abandonedFile = try publish(abandoned)
        try await until { homeLookups > previousLookups }
        try fm.removeItem(at: abandonedFile); ready = home
        let following = EditorBridge.Request(operation: "status"); _ = try publish(following)
        try await until { fm.fileExists(atPath: transport.appendingPathComponent(following.id.uuidString + ".response.json").path) }
        check(!fm.fileExists(atPath: transport.appendingPathComponent(abandoned.id.uuidString + ".response.json").path), "A cancelled client does not leave a late response file")
        let opener = HomeModel(index: LibraryIndex(location: output.appendingPathComponent("opener.sqlite")), overleaf: OverleafLibrary(directory: output.appendingPathComponent("opener-account")))
        opener.error = "A previous operation failed"; opener.overleaf.browsing = true; ready = opener
        let openURL = output.appendingPathComponent("open-fixture.md")
        try "# A fresh request".write(to: openURL, atomically: true, encoding: .utf8)
        let openRequest = EditorBridge.Request(operation: "open", file: openURL.path); _ = try publish(openRequest)
        let openReply = transport.appendingPathComponent(openRequest.id.uuidString + ".response.json")
        try await until { fm.fileExists(atPath: openReply.path) && opener.reader.url == openURL }
        check(try (JSONSerialization.jsonObject(with: Data(contentsOf: openReply)) as? [String: Any])?["ok"] as? Bool == true && opener.error == nil && !opener.overleaf.browsing, "CLI open clears stale errors and reveals the requested reader instead of the Overleaf list")
        opener.overleaf.browsing = true; opener.newMarkdown()
        check(opener.reader.isUntitled && !opener.overleaf.browsing, "New Markdown leaves the Overleaf list and reveals the new document")
        service.cancel(); await service.value
        func hit(_ path: String, _ excerpt: String) -> LibraryHit { LibraryHit(path: path, folderID: "fixture", page: 1, excerpt: excerpt, score: 1) }
        home.results = [hit("/a.tex", "first"), hit("/b.tex", "second")]
        check(home.resultGroups.count == 2 && home.rankedHits.count == 2, "Search retains grouped and ranked views of the same results")
        home.documentFilter = "a.tex"
        check(home.resultGroups.count == 1 && home.rankedHits.count == 1, "Changing the document filter invalidates both result views")
        home.results = [hit("/a.tex", "updated")]
        check(home.resultGroups[0].hits[0].excerpt == "updated", "Replacing an excerpt under the same hit ID invalidates derived results")
        let cacheRoot = output.appendingPathComponent("cache"), allocated = TeXCache.allocate("LaTeX", under: cacheRoot)
        try fm.createDirectory(at: allocated, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: allocated.appendingPathComponent("temporary"))
        let active = TeXCache.activeCount; TeXCache.discard(allocated)
        check(TeXCache.activeCount == active - 1, "Discard relinquishes only the owned build folder")
        try await until { !fm.fileExists(atPath: allocated.path) }
        check(!fm.fileExists(atPath: allocated.path), "The utility queue removes discarded build files")
        let keep = cacheRoot.appendingPathComponent("user-file"); try Data([1]).write(to: keep)
        TeXCache.discard(keep); check(fm.fileExists(atPath: keep.path), "Cache disposal cannot remove an unowned path")
        let width = 6000, height = 3000
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.gray.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let png = NSMutableData(), destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(destination))
        let before = SourceDigest.sha256((png as Data).base64EncodedString())
        let preview = TeXAssetData.document(png as Data, extension: "png")!
        let bounds = preview.page(at: 0)!.bounds(for: .mediaBox)
        check(max(bounds.width, bounds.height) <= CGFloat(TeXAssetData.imagePixelLimit), "Large raster previews use bounded pixel dimensions")
        check(abs(bounds.width / bounds.height - 2) < 0.01, "Downsampling preserves the figure aspect ratio")
        check(SourceDigest.sha256((png as Data).base64EncodedString()) == before, "Preview downsampling never rewrites source bytes")
        check(TeXAssetData.document(Data("invalid".utf8), extension: "png") == nil, "Invalid image data does not create a misleading preview")
        let memory = RuntimeDiagnostics.memory(); check(memory["scope"] as? String == "mainProcessOnly", "Diagnostics explicitly exclude helper-process memory")
        let hint = NSHostingView(rootView: SettingsHint("Questions and document context are sent to ChatGPT.").frame(width: 210).foregroundStyle(RemileStyle.ink))
        check(hint.fittingSize.height > 25, "A narrow settings hint wraps instead of becoming an ellipsis")
        let guideState = UserGuidePresentation(); guideState.more = true
        let host = NSHostingView(rootView: UserGuide(presentation: guideState).environment(\.colorScheme, .dark).foregroundStyle(RemileStyle.ink))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: image); try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("guide.png")) }
        window.orderOut(nil)
        try JSONSerialization.data(withJSONObject: ["checks": passed, "previewWidth": bounds.width, "previewHeight": bounds.height, "memory": memory], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("metrics.json"))
        print("Passed \(passed) resource and UX checks"); exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
app.run()
