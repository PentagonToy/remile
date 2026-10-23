import AppKit
import SwiftUI
import PDFKit
import WebKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
@MainActor func waitFor(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<100 { if try await predicate() { return }; try await Task.sleep(for: .milliseconds(40)) }
    throw NSError(domain: "EditorChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out"])
}
Task { @MainActor in
    do {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let aligned = "\\begin{align} y&=2x^2 \\\\ &=5x-b \\end{align}"
        let xml = try MathMarkup.render(aligned, display: true)
        expect(xml.contains("columnalign=\"right left\""), "Align uses right/left columns")
        expect(MarkdownEditing.pair("", range: NSRange(location: 0, length: 0), replacement: "(")?.text == "()", "Pair parentheses")
        expect(MarkdownEditing.pair("()", range: NSRange(location: 1, length: 0), replacement: ")")?.selection.location == 2, "Skip existing closer")
        expect(MarkdownEditing.pair("$$", range: NSRange(location: 1, length: 0), replacement: "$")?.text == "$$\n\n$$", "Promote display math fence")
        expect(MarkdownEditing.newline("\\begin{align}", selection: NSRange(location: 13, length: 0))?.text.contains("\\end{align}") == true, "Complete environment")
        let reader = ReadingSession(); expect(reader.newMarkdown(), "Create untitled Markdown")
        expect(reader.isUntitled && !reader.dirty && reader.url?.lastPathComponent == "Untitled.md", "An empty untitled editor does not require Save")
        let controller = MarkdownEditorController(), scroll = controller.makeView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll; window.orderFront(nil)
        controller.update("", size: 18, serif: false)
        let textView = controller.textView!; window.makeFirstResponder(textView)
        textView.insertText("(", replacementRange: NSRange(location: 0, length: 0))
        expect(textView.string == "()" && textView.selectedRange().location == 1, "Native delimiter transaction")
        controller.update("# Title\n\nFind this word", size: 18, serif: false)
        controller.reveal(line: 2, text: "word")
        expect((textView.string as NSString).substring(with: textView.selectedRange()) == "word", "Preview selection reveals exact source word")
        expect(scroll.verticalScrollElasticity == .allowed, "Native rubber-banding is enabled")
        let preview = MarkdownPreviewModel(); preview.web.frame = CGRect(x: 0, y: 0, width: 720, height: 700)
        let file = output.appendingPathComponent("fixture.md")
        let source = "# Example\n\n$$\n" + aligned + "\n$$\n\nSome words."
        await preview.render(source, url: file); preview.display(dark: true, scale: 1, wide: false, serif: false)
        try await waitFor { (try? await preview.web.evaluateJavaScript("document.querySelectorAll('mtable').length")) as? Int == 1 }
        let positions = try await preview.web.evaluateJavaScript("[...document.querySelectorAll('mtable mo')].filter(e=>e.textContent==='=').map(e=>e.getBoundingClientRect().x)") as! [Double]
        expect(positions.count == 2 && abs(positions[0] - positions[1]) < 1, "WebKit aligns both equals signs")
        _ = try await preview.web.evaluateJavaScript("window.previewSentinel=42")
        await preview.render(source + "\n\nUpdated paragraph", url: file)
        preview.display(dark: true, scale: 1, wide: false, serif: false)
        try await waitFor { (try? await preview.web.evaluateJavaScript("document.body.innerText.includes('Updated paragraph')")) as? Bool == true }
        let sentinel = try await preview.web.evaluateJavaScript("window.previewSentinel") as? Int
        expect(sentinel == 42, "Live update does not navigate or replace WebKit document")
        let background = try await preview.web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        expect(background == "rgb(35, 33, 32)", "Theme survives atomic body update")
        var jump: (Int, String)?
        preview.sourceSelection = { jump = ($0,$1) }
        _ = try await preview.web.evaluateJavaScript("window.webkit.messageHandlers.sourceLocation.postMessage({line:8,text:'words'});true")
        try await waitFor { jump != nil }
        expect(jump?.0 == 8 && jump?.1 == "words", "Local source bridge forwards line and selected text")
        let image = try await preview.web.takeSnapshot(configuration: nil)
        if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) { try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("aligned-preview.png")) }
        let pdf = try Data(contentsOf: URL(fileURLWithPath: "/Volumes/PentagonToy/Workspace/Agents/Repository/remile/2026-10-19-interaction-polish/checks/A recent document.pdf"))
        let session = PDFSession(); session.load(pdf)
        let view = PDFView(); view.document = session.document; session.attach(view)
        session.loadComments(); try await waitFor { !session.loadingComments }
        let before = session.comments.count
        let selection = session.document!.page(at: 0)!.selection(for: NSRange(location: 0, length: 5))!
        view.setCurrentSelection(selection, animate: false); session.highlightSelection()
        expect(session.editingError == nil, "Highlight writes verified pending bytes")
        session.loadComments(); try await waitFor { !session.loadingComments }
        expect(session.comments.count == before && session.highlights.count == 1, "Highlight is separate from comments")
        expect(session.highlights.first?.annotation.contents == nil, "New highlight has no automatic comment")
        session.showsOverview = true
        let destination = session.document!.outlineRoot!.child(at: 0)!.destination!
        session.goToOutline(destination)
        expect(!session.showsOverview && session.currentPage == 6, "Outline exits overview and navigates to target")
        try session.committedData!.write(to: output.appendingPathComponent("highlighted.pdf"))
        window.orderOut(nil); session.stop()
        print("\(checks) editor polish checks passed"); exit(0)
    } catch { print("Editor polish checks failed: \(error)"); exit(1) }
}
RunLoop.main.run()
