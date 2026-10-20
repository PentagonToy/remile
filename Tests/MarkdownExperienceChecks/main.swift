import AppKit
import WebKit
import PDFKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}

var checks = 0
func verify(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label); checks += 1 }
func applied(_ source: String, _ change: MarkdownEditing.Change) -> String { (source as NSString).replacingCharacters(in: change.range, with: change.text) }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
var finished = false
let application = NSApplication.shared
Task { @MainActor in
    let unicode = "한글 👩🏽‍💻 text"
    let selection = (unicode as NSString).range(of: "👩🏽‍💻")
    let wrapped = MarkdownEditing.wrap(unicode, selection: selection, before: "**", after: "**")
    verify(applied(unicode, wrapped) == "한글 **👩🏽‍💻** text", "UTF-16 formatting preserves composed emoji")
    verify(wrapped.selection.length == selection.length, "Formatting retains selection")
    let lines = "one\ntwo\nthree"
    let prefixed = MarkdownEditing.prefix(lines, selection: NSRange(location: 0, length: 4), marker: "- ")
    verify(applied(lines, prefixed) == "- one\ntwo\nthree", "Selection ending at next line does not format that line")
    for (source, expected) in [("- item", "- item\n- "), ("9. item", "9. item\n10. "), ("  - [x] done", "  - [x] done\n  - [ ] "), ("> quote", "> quote\n> "), ("- ", "")] {
        let change = MarkdownEditing.newline(source, selection: NSRange(location: (source as NSString).length, length: 0))!
        verify(applied(source, change) == expected, "List continuation: \(source)")
    }
    verify(MarkdownEditing.newline("\(Int.max). item", selection: NSRange(location: "\(Int.max). item".utf16.count, length: 0)) == nil, "Huge ordered marker cannot overflow")
    verify(MarkdownEditing.newline("plain", selection: NSRange(location: 5, length: 0)) == nil, "Ordinary newline remains native")
    verify(ReadableMath.display(#"The \(k-\epsilon\) model"#) == "The k–ε model", "Readable turbulence notation")
    verify(ReadableMath.display(#"$\alpha + \beta$"#) == "α + β", "Paired formula delimiters")
    verify(ReadableMath.display("Costs $5 to $10 today") == "Costs $5 to $10 today", "Currency retained")
    verify(ReadableMath.display("Costs $5 + tax, then $10") == "Costs $5 + tax, then $10", "Currency arithmetic retained")
    verify(ReadableMath.display(#"`\epsilon` and ``a ` \epsilon``"#) == #"`\epsilon` and ``a ` \epsilon``"#, "Inline code retained")
    verify(ReadableMath.display("```tex\n\\epsilon\n```") == "```tex\n\\epsilon\n```", "Code fence retained")
    verify(ReadableMath.display("```tex\n~~~\n\\epsilon\n```") == "```tex\n~~~\n\\epsilon\n```", "Different marker does not close code fence")
    verify(ReadableMath.display(#"\frac{a}{b}"#) == "(a)/(b)", "Simple fraction remains readable")
    verify(ReadableMath.display(#"\unknown{x}"#) == #"\unknown{x}"#, "Unknown commands are not discarded")
    let controller = MarkdownEditorController()
    let scroll = controller.makeView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentView = scroll
    controller.update(unicode, size: 17, serif: false)
    let view = controller.textView!
    view.setSelectedRange(selection)
    // A normal window supplies the native text Undo manager.
    window.makeFirstResponder(view)
    verify(view.font?.pointSize == 17, "Source font is 17 points at actual size")
    verify(controller.makeView() === scroll, "Mode remount reuses scroll view and text storage")
    window.contentView = scroll
    verify(view.selectedRange() == selection, "Mode remount preserves selection")
    view.undoManager?.beginUndoGrouping()
    controller.wrap("**", "**", name: "Bold")
    view.undoManager?.endUndoGrouping()
    verify(view.string == "한글 **👩🏽‍💻** text", "Native insertion uses correct source range")
    verify(view.undoManager?.canUndo == true, "Formatting registers native Undo")
    view.undoManager?.undo()
    verify(view.string == unicode, "Native Undo restores canonical source")
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let composing = view.string
    controller.update("external refresh", size: 17, serif: false)
    verify(view.hasMarkedText() && view.string == composing, "Refresh does not replace active IME composition")
    view.unmarkText()
    controller.update("# Title\n\n한국어 and emoji 👋", size: 17, serif: false)
    let canonical = view.string
    try? await Task.sleep(for: .milliseconds(250))
    verify(view.string == canonical, "Syntax styling does not rewrite source")
    let preview = MarkdownPreviewModel()
    let fixture = output.appendingPathComponent("experience.md")
    let source = "# A readable document\n\n한국어 and **emphasis**, $k-\\epsilon$.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
    await preview.render(source, url: fixture)
    verify(preview.html?.contains("<math") == true && preview.html?.contains("<table>") == true, "Preview supports math and tables")
    let good = preview.html
    await preview.render("```unfinished", url: fixture)
    verify(preview.html == good && preview.message != nil, "Incomplete source retains last successful preview")
    await preview.render(source, url: fixture)
    verify(preview.message == nil && preview.sections.count == 1, "Completed source recovers preview and outline")
    preview.web.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
    preview.display(dark: false, scale: 1, wide: false, serif: false)
    var font: String?
    for _ in 0..<100 {
        try? await Task.sleep(for: .milliseconds(50))
        font = try? await preview.web.evaluateJavaScript("getComputedStyle(document.body).fontSize") as? String
        if font == "18px" { break }
    }
    verify(font == "18px", "WebKit loads preview with readable 18px body")
    preview.display(dark: true, scale: 1.5, wide: false, serif: true)
    verify(preview.web.pageZoom == 1.5, "Preview zoom updates persistent WebKit view")
    let start = Date()
    let large = "# Large fixture\n\n" + String(repeating: "A paragraph with **emphasis** and 한국어.\n\n", count: 2500)
    await preview.render(large, url: fixture)
    verify(preview.message == nil && preview.html != nil, "Large fixture renders without blocking editor storage")
    let elapsed = Date().timeIntervalSince(start)
    var printRenderer = MarkdownHTML(baseURL: fixture)
    let printSource = source + "\n\n" + (1...120).map { "Paragraph \($0). A printable paragraph with **emphasis** and inline `code`." }.joined(separator: "\n\n") + "\n\nEND PRINT FIXTURE"
    let printOutput = output.appendingPathComponent("markdown-print.pdf")
    try! await MarkdownPDF.write(try! printRenderer.document(printSource), to: printOutput)
    let printed = PDFDocument(url: printOutput)!
    verify(printed.pageCount > 1, "Markdown print content paginates")
    verify(printed.string?.contains("END PRINT FIXTURE") == true, "Print preserves final content")
    verify(printed.page(at: 0)?.bounds(for: .mediaBox).size == NSSize(width: 612, height: 792), "Print output has paper bounds")
    verify(printed.printOperation(for: NSPrintInfo.shared.copy() as? NSPrintInfo, scalingMode: .pageScaleToFit, autoRotate: true) != nil, "Rendered Markdown prepares native print operation")
    for index in [0, printed.pageCount - 1] {
        let image = printed.page(at: index)!.thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox)
        if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            try! png.write(to: output.appendingPathComponent("print-page-\(index + 1).png"))
        }
    }
    print("\(checks) Markdown experience checks passed; \(large.utf8.count)-byte fixture render including debounce: \(elapsed) seconds; \(printed.pageCount) print pages")
    window.orderOut(nil); finished = true
}
while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
