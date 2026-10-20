import AppKit
import SwiftUI
import WebKit
import PDFKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0 }
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); checks += 1 }
Task { @MainActor in
    do {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        let main = "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}\n"
        try main.write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try "\\section{First}\nBody\n\\subsection{Nested}\n% \\section{Ignored}".write(to: root.appendingPathComponent("contents/part.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(root)
        expect(project.selected == "main.tex", "Main opens")
        project.newFile(); expect(project.finishNewItem(" ") && project.newItemDraft == nil, "Blank file creation cancels")
        project.newFile(); expect(!project.finishNewItem("../escape.tex"), "New files reject traversal"); project.cancelNewItem()
        project.newFile(); expect(!project.finishNewItem("main.tex"), "New files preserve an existing source"); project.cancelNewItem()
        project.newFile(); expect(project.finishNewItem("chapter.tex"), "Source file is created")
        expect(project.selected == "chapter.tex" && project.buffers["chapter.tex"] == "" && !project.dirty, "New source opens as a clean empty buffer")
        let newSource = try Data(contentsOf: root.appendingPathComponent("chapter.tex")); expect(newSource.isEmpty, "New source is empty on disk")
        project.newItemDraft = .init(kind: .rename("chapter.tex"))
        expect(project.finishNewItem("section.tex") && project.selected == "section.tex", "Inline rename remaps new source selection")
        project.newItemDraft = .init(kind: .rename("section.tex"))
        expect(project.finishNewItem("") && project.treeFiles.contains("section.tex"), "Blank rename preserves the existing file")
        project.newFolder(); expect(project.finishNewItem("notes"), "Inline folder creation commits")
        project.addCollection(); expect(project.finishNewItem(" ") && project.collections.isEmpty, "Blank collection cancels")
        project.addCollection(); expect(project.finishNewItem("Sources") && project.collections.count == 1, "Virtual collection persists")
        expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path), "Collection leaves source paths unchanged")
        project.newItemDraft = .init(kind: .renameCollection(project.collections[0].id, "Sources"))
        expect(project.finishNewItem("References") && TeXCollections.read(root).first?.name == "References", "Inline collection rename persists")
        project.newFile(); project.cancelNewItem(); expect(project.newItemDraft == nil, "Explicit cancellation drops the draft")
        project.selected = "main.tex"
        project.selected = "contents/part.tex"; project.goBack(); expect(project.selected == "main.tex", "Back navigation")
        project.goForward(); expect(project.selected == "contents/part.tex", "Forward navigation")
        let outline = TeXOutlineItem.parse(project.source.wrappedValue)
        expect(outline.count == 2 && outline.last?.level == 1, "Outline excludes comments and retains hierarchy")
        project.move("contents/part.tex", to: "other/renamed.tex")
        expect(project.buffers["other/renamed.tex"] != nil && project.buffers["contents/part.tex"] == nil, "Move remaps the editor buffer")
        expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("other/renamed.tex").path), "Move reaches disk")
        do { try TeXFileSystem.move(root: root, from: "main.tex", to: "other/renamed.tex"); fatalError("Collision allowed") } catch { checks += 1 }
        do { _ = try TeXFileSystem.url("../escape.tex", root: root); fatalError("Traversal allowed") } catch { checks += 1 }
        let before = project.source.wrappedValue
        project.captureHistory(file: project.selected)
        project.source.wrappedValue += "\nNew edit"
        project.captureHistory(file: project.selected)
        let old = project.revisions.first { $0.file == project.selected && $0.source == before }!
        project.restore(old)
        expect(project.source.wrappedValue == before, "History restores into the buffer")
        let saved = try String(contentsOf: root.appendingPathComponent(project.selected), encoding: .utf8)
        expect(saved == before, "History does not write changes automatically")
        project.buffers["main.tex"] = main + "% unsaved"
        try (main + "% external").write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        expect(!project.save(), "External save conflict is preserved")
        expect(EditorBridge.digest("a") != EditorBridge.digest("b"), "CLI uses source fingerprints")
        expect(RecentReadingRow.relativeDate(Date()) == "Today", "Recent opening dates")
        let now = Date(timeIntervalSince1970: 10000)
        expect(OverleafLibrary.syncAge(now.addingTimeInterval(-59), now: now) == "Synced just now", "Sync age never shows seconds")
        expect(OverleafLibrary.syncAge(now.addingTimeInterval(-119), now: now) == "Synced 1 min ago", "Sync age rounds down to whole minutes")
        expect(OverleafLibrary.syncAge(now.addingTimeInterval(60), now: now) == "Synced just now", "Future sync dates stay non-negative")
        let linked = try TeXProject(root, historyEnabled: false, displayName: "Online title")
        var confirmation: CheckedContinuation<Void, Error>?
        linked.renameConnectedProject = { _ in try await withCheckedThrowingContinuation { confirmation = $0 } }
        expect(linked.renameProject(to: "New / title"), "Connected titles accept slashes as metadata")
        while confirmation == nil { await Task.yield() }
        expect(linked.displayName == "Online title" && linked.renamingProject, "Remote title waits for confirmation")
        confirmation?.resume(); confirmation = nil
        while linked.renamingProject { await Task.yield() }
        expect(linked.displayName == "New / title" && linked.root == root, "Confirmed rename changes the title without moving local files")
        linked.renameConnectedProject = { _ in throw OverleafProjectRename.Failure.permission }
        expect(linked.renameProject(to: "Denied title"), "Connected rename begins")
        while linked.renamingProject { await Task.yield() }
        expect(linked.displayName == "New / title" && linked.message?.hasPrefix("Rename failed:") == true, "Failed remote rename preserves the title")
        do { _ = try OverleafProjectRename.path(projectID: "../escape", name: "Title"); fatalError("Invalid remote id accepted") } catch { checks += 1 }
        do { _ = try OverleafProjectRename.path(projectID: String(repeating: "a", count: 24), name: String(repeating: "x", count: 151)); fatalError("Long remote title accepted") } catch { checks += 1 }
        let loader = RenameFixtureLoader()
        try await loader.load()
        let title = "Quoted \"title\" / 한글"
        let path = try OverleafProjectRename.path(projectID: String(repeating: "a", count: 24), name: title)
        let response: Any = try await withCheckedThrowingContinuation { continuation in
            loader.web.callAsyncJavaScript("window.fetch = async (path, options) => { window.request = { path, ...options }; return { status: 200 }; };\n" + OverleafProjectRename.script, arguments: ["renamePath": path, "newProjectName": title], in: nil, in: .page) { continuation.resume(with: $0) }
        }
        expect((response as? NSNumber)?.intValue == 200, "Remote rename accepts a confirmed response")
        let request = try await loader.web.evaluateJavaScript("window.request") as! [String: Any]
        let body = try JSONSerialization.jsonObject(with: (request["body"] as! String).data(using: .utf8)!) as! [String: String]
        expect(request["path"] as? String == path && body["newProjectName"] == title, "Rename sends the official field and preserves Unicode and quotes as data")
        expect(request["credentials"] as? String == "same-origin" && request["redirect"] as? String == "error" && (request["headers"] as? [String: String])?["X-Csrf-Token"] == "fixture-token", "Rename uses the current origin and CSRF token without following redirects")
        let pdf = PDFDocument(); pdf.insert(PDFPage(image: NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true })!, at: 0)
        try pdf.dataRepresentation()!.write(to: root.appendingPathComponent("figure.pdf"))
        let pdfBytes = try TeXAssetData.load(root: root, path: "figure.pdf", configuration: .current)
        expect(PDFDocument(data: pdfBytes)?.pageCount == 1, "PDF assets load independently of the compiled result")
        let eps = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 32 32\nnewpath 0 0 moveto 32 32 lineto stroke\nshowpage\n%%EOF\n"
        try eps.write(to: root.appendingPathComponent("figure.eps"), atomically: true, encoding: .utf8)
        let epsBytes = try await Task.detached { try TeXAssetData.load(root: root, path: "figure.eps", configuration: .current) }.value
        expect(PDFDocument(data: epsBytes)?.pageCount == 1, "EPS assets convert into a readable preview")
        let unchanged = try String(contentsOf: root.appendingPathComponent("figure.eps"), encoding: .utf8)
        expect(unchanged == eps && !FileManager.default.fileExists(atPath: root.appendingPathComponent("image.pdf").path), "EPS preview leaves the project unchanged")
        project.selected = "figure.pdf"; project.source.wrappedValue = "must not become source"
        expect(project.buffers["figure.pdf"] == nil, "Asset selection cannot create an editable binary buffer")
        let cache = root.appendingPathComponent("cache/LaTeX")
        let oldest = cache.appendingPathComponent(UUID().uuidString), newest = cache.appendingPathComponent(UUID().uuidString), unknown = cache.appendingPathComponent("keep-user-folder")
        for folder in [oldest, newest, unknown] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try Data(repeating: 1, count: 20).write(to: folder.appendingPathComponent("data")) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86400)], ofItemAtPath: oldest.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newest.path)
        TeXCache.prune(at: cache.deletingLastPathComponent(), now: now, budget: 25)
        expect(!FileManager.default.fileExists(atPath: oldest.path) && FileManager.default.fileExists(atPath: newest.path), "Cache pruning removes old builds within its budget")
        expect(FileManager.default.fileExists(atPath: unknown.path), "Cache pruning leaves unrecognised folders alone")
        print("Passed \(checks) editor workflow checks")
        exit(0)
    } catch { print(error); exit(1) }
}
RunLoop.main.run()

@MainActor final class RenameFixtureLoader: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: .zero, configuration: { let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); return config }())
    private var continuation: CheckedContinuation<Void, Error>?
    func load() async throws {
        web.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in self.continuation = continuation; web.loadHTMLString("<meta name='ol-csrfToken' content='fixture-token'><p>Fixture</p>", baseURL: URL(string: "https://www.overleaf.com/project")) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
