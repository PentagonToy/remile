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
    preview.display(dark: true, scale: 1, wide: false, serif: false)
    verify(preview.web.isHidden, "Cold preview stays hidden before its first themed document")
    verify(preview.web.underPageBackgroundColor == RemileStyle.slate, "Dark background is set even before HTML exists")
    let fixture = output.appendingPathComponent("experience.md")
    let editOnly = MarkdownPreviewModel()
    await editOnly.render("# Draft\n\nTwo words.", url: fixture, includeHTML: false)
    verify(editOnly.html == nil && editOnly.sections.first?.title == "Draft" && editOnly.wordCount == 4, "Edit-only mode updates the outline and word count without rendering HTML")
    await editOnly.render("# Draft\n\nTwo words.", url: fixture)
    let draftHTML = editOnly.html
    await editOnly.render("# Revised draft", url: fixture, includeHTML: false)
    verify(draftHTML != nil && editOnly.html == draftHTML && editOnly.sections.first?.title == "Revised draft", "Editing retains the last HTML while the outline follows the source")
    await editOnly.render("# Revised draft", url: fixture)
    verify(editOnly.html?.contains("Revised draft") == true, "Returning to the preview renders the latest source")

    let session = ReadingSession()
    session.document.content = .markdown("Before")
    let undo = UndoManager()
    verify(!session.replaceMarkdown(before: "Stale", after: "After", undoManager: undo), "Read-only CLI edits reject stale source")
    verify(session.replaceMarkdown(before: "Before", after: "After", undoManager: undo), "Read-only CLI edits update the document")
    undo.undo()
    verify(String(decoding: session.bytes, as: UTF8.self) == "Before", "Read-only CLI edits can be undone")
    undo.redo()
    verify(String(decoding: session.bytes, as: UTF8.self) == "After", "Read-only CLI edits can be redone")

    await preview.render("   ", url: fixture)
    verify(preview.html != nil && !preview.showsWebPreview, "Blank Markdown keeps the native preview background")
    let source = #"""
    # A readable document

    한국어 and **emphasis**, $k-\epsilon$.

    [Read the **paper**](https://example.invalid/paper).

    $$
    \begin{array}{lr} \oiint_S & \cancel{x} \\ \textbf{fuel} & \ddot{u} \end{array}
    $$

    | A | B |
    | --- | --- |
    | 1 | 2 |
    """#
    await preview.render(source, url: fixture)
    verify(preview.showsWebPreview, "Nonempty Markdown displays the web preview")
    verify(preview.html?.contains("<math") == true && preview.html?.contains("<table>") == true, "Preview supports math and tables")
    let good = preview.html
    await preview.render("```unfinished", url: fixture)
    verify(preview.html == good && preview.message != nil, "Incomplete source retains last successful preview")
    await preview.render(source, url: fixture)
    verify(preview.message == nil && preview.sections.count == 1, "Completed source recovers preview and outline")
    preview.web.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
    preview.display(dark: true, scale: 1, wide: false, serif: false)
    var font: String?
    for _ in 0..<100 {
        try? await Task.sleep(for: .milliseconds(50))
        font = try? await preview.web.evaluateJavaScript("getComputedStyle(document.body).fontSize") as? String
        if font == "18px" { break }
    }
    verify(font == "18px", "WebKit loads preview with readable 18px body")
    let browserLink = try? await preview.web.evaluateJavaScript("""
    (() => {
      const links = document.querySelectorAll('a[data-browser-link]');
      return links.length === 1 && links[0].textContent === 'Read the paper'
        && getComputedStyle(links[0], '::after').content.includes('↗');
    })()
    """) as? Bool
    verify(browserLink == true, "WebKit displays one browser arrow beside a formatted link")
    let formulaLayout = try? await preview.web.evaluateJavaScript("""
    (() => {
      const math = document.querySelector('math[display="block"]');
      const cells = math?.querySelectorAll('mtd');
      const strike = math?.querySelector('menclose');
      return math?.getBoundingClientRect().height > 0 && cells?.length === 4
        && getComputedStyle(cells[0]).textAlign === 'left'
        && getComputedStyle(cells[1]).textAlign === 'right'
        && strike?.getBoundingClientRect().width > 0
        && !document.querySelector('.math-source');
    })()
    """) as? Bool
    verify(formulaLayout == true, "WebKit lays out a TeX array with aligned columns and a cancellation term")
    verify(!preview.web.isHidden, "Themed document reveals the initial preview")
    let background = try? await preview.web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
    verify(background == "rgb(32, 44, 53)", "First document paint uses the dark canvas")
    preview.display(dark: false, scale: 1, wide: false, serif: false)
    verify(preview.web.underPageBackgroundColor == RemileStyle.paper, "Light native canvas updates without replacing WebKit")
    preview.display(dark: true, scale: 1.5, wide: false, serif: true)
    verify(preview.web.pageZoom == 1.5, "Preview zoom updates persistent WebKit view")
    preview.display(dark: true, scale: 1, wide: true, serif: true)
    let wide = try? await preview.web.evaluateJavaScript("getComputedStyle(document.body).maxWidth") as? String
    verify(wide == "none" && preview.web.pageZoom == 1, "Fit width uses the preview viewport at normal text scale")
    let searchPreview = SearchMarkdownCanvas.Coordinator()
    searchPreview.loaded = true; searchPreview.wide = true
    searchPreview.applyReadingWidth(preview.web)
    let searchWide = try? await preview.web.evaluateJavaScript("document.body.style.maxWidth") as? String
    verify(searchWide == "none", "Search preview honours Fit width")
    searchPreview.wide = false
    searchPreview.applyReadingWidth(preview.web)
    let readingWidth = try? await preview.web.evaluateJavaScript("document.body.style.maxWidth") as? String
    verify(readingWidth == "850px", "Search preview restores its reading width")
    let searchWeb = WKWebView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
    searchWeb.navigationDelegate = searchPreview
    searchPreview.loaded = false
    searchPreview.web = searchWeb
    searchPreview.section = 1
    searchPreview.query = "flamelet"
    let searchHTML = """
    <span id="section-1"></span><p>first flamelet</p>
    <div style="height:600px"></div><span id="section-2"></span><p>second flamelet</p>
    """
    searchPreview.navigation = searchWeb.loadHTMLString(searchHTML, baseURL: nil)
    var marked = 0
    for _ in 0..<100 {
        try? await Task.sleep(for: .milliseconds(30))
        marked = (try? await searchWeb.evaluateJavaScript("document.querySelectorAll('mark').length") as? Int) ?? 0
        if marked == 2 { break }
    }
    verify(marked == 2, "Search marks both occurrences across Markdown sections")
    _ = try? await searchWeb.evaluateJavaScript("window.firstMark = document.querySelector('mark'); true")
    searchPreview.section = 2
    searchPreview.dark = true
    searchPreview.applyAppearance(searchWeb)
    searchPreview.reveal(searchWeb)
    let reusedHighlights = try? await searchWeb.evaluateJavaScript("""
    window.firstMark === document.querySelector('mark') && scrollY > 300
        && getComputedStyle(document.body).backgroundColor === 'rgb(34, 44, 53)'
    """) as? Bool
    verify(reusedHighlights == true, "Changing appearance and revealing another section reuses the existing marks")
    searchPreview.citation = AssistantCitation(location: .init(path: fixture.path, unit: 2, label: "Second"), text: "second flamelet")
    searchPreview.refreshHighlights(searchWeb)
    var quoted: String?
    for _ in 0..<100 {
        try? await Task.sleep(for: .milliseconds(30))
        quoted = try? await searchWeb.evaluateJavaScript("document.querySelector('mark')?.textContent ?? ''") as? String
        if quoted == "second flamelet" { break }
    }
    verify(quoted == "second flamelet", "A citation still highlights the excerpt within its section")
    searchPreview.cancelHighlighting()
    let start = Date()
    let large = "# Large fixture\n\n" + String(repeating: "A paragraph with **emphasis** and 한국어.\n\n", count: 3000)
    await preview.render(large, url: fixture)
    verify(preview.message == nil && preview.html != nil, "Large fixture renders without blocking editor storage")
    let elapsed = Date().timeIntervalSince(start)
    preview.display(dark: true, scale: 1, wide: true, serif: true)
    await preview.render(large + "\n\n## 최신 👋\n\n**Updated preview**", url: fixture)
    preview.display(dark: true, scale: 1, wide: true, serif: true)
    preview.reveal(section: 2)
    var newest: String?
    for _ in 0..<100 {
        newest = try? await preview.web.evaluateJavaScript("document.querySelector('h2')?.textContent") as? String
        if newest == "최신 👋" { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    verify(newest == "최신 👋" && preview.message == nil, "Live body replacement renders the latest Unicode heading")
    let sectionVisible = try? await preview.web.evaluateJavaScript("""
        (() => {const heading = document.querySelector('h2').getBoundingClientRect();
        return heading.top >= 0 && heading.bottom <= innerHeight})()
        """) as? Bool
    verify(sectionVisible == true, "Outline navigation reaches a heading in the new body")
    verify(preview.wordCount == (large + "\n\n## 최신 👋\n\n**Updated preview**").split(whereSeparator: \.isWhitespace).count,
           "Streaming word count agrees with the existing whitespace rules")
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
