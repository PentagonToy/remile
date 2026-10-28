import CoreText

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
var checks = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1; print("PASS: " + message); fflush(stdout) }
func key(_ code: UInt16, shift: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
}
Task { @MainActor in
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 960, height: 540)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for number in 1...3 {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.02, green: 0.09, blue: 0.22, alpha: 1)); context.fill(box)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 90, y: 270)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 56, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Slide \(number)", attributes: attributes)), context)
        context.endPDFPage()
    }
    context.closePDF()
    let source = output.appendingPathComponent("slides.pdf"), originalBytes = data as Data
    try! originalBytes.write(to: source)
    let document = PDFDocument(data: originalBytes)!
    let note = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 20, height: 20), forType: .text, withProperties: nil)
    note.contents = "Pending note"; document.page(at: 0)!.addAnnotation(note)
    let originalText = document.string
    check(originalText?.contains("Slide 2") == true, "The fixture contains actual PDF text")
    let reader = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    reader.document = document; reader.displayMode = .twoUpContinuous; reader.autoScales = false; reader.scaleFactor = 1.25
    let view = PDFSlideView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view; window.makeKeyAndOrderFront(nil)
    view.document = document; view.layoutDocumentView()
    @MainActor func page() -> Int { document.index(for: view.currentPage!) + 1 }
    check(view.document === reader.document, "Slides reuse the open PDF without a second document parse")
    check(view.displayMode == .singlePage && view.autoScales && !view.displaysPageBreaks, "One page fits the slide canvas without continuous scrolling")
    view.keyDown(with: key(123)); check(page() == 1, "Previous at the first slide stays at the first slide")
    view.keyDown(with: key(124)); check(page() == 2, "Right advances one slide")
    view.keyDown(with: key(125)); check(page() == 3, "Down advances one slide")
    view.keyDown(with: key(124)); check(page() == 3, "Next at the last slide stays at the last slide")
    view.keyDown(with: key(126)); check(page() == 2, "Up returns one slide")
    view.keyDown(with: key(49, shift: true)); check(page() == 1, "Shift-Space returns one slide")
    view.keyDown(with: key(49)); check(page() == 2, "Space advances one slide")
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    view.mouseDown(with: click); check(page() == 3, "A primary click advances without selecting text or following links")
    view.rightMouseDown(with: click); check(page() == 2, "A secondary click returns one slide")
    var exited = false; view.finish = { exited = true }
    view.keyDown(with: key(53)); check(exited, "Escape exits slide view")
    check(view.accessibilityCustomActions()?.count == 3, "Accessible actions expose next, previous and exit")
    check(reader.scaleFactor == 1.25 && reader.displayMode == .twoUpContinuous, "Slide navigation does not change reader zoom or layout")
    try! await Task.sleep(for: .milliseconds(400))
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("slides.png"))
    if CommandLine.arguments.contains("--fullscreen") {
        let presentation = PDFSlidePresentation(); var returned: Int?
        presentation.start(document: document, page: 2) { returned = $0 }
        check(presentation.view?.isInFullScreenMode == true, "Slide view enters native full screen")
        check(presentation.view?.window?.firstResponder === presentation.view, "The full-screen canvas receives keyboard input")
        presentation.view?.keyDown(with: key(124))
        presentation.finish(); presentation.finish()
        check(returned == 3 && presentation.view == nil, "Exiting returns the last page and releases the slide canvas once")
        presentation.start(document: PDFDocument(), page: 1) { _ in preconditionFailure("Empty document presented") }
        check(presentation.view == nil, "An empty PDF cannot enter slide view")
        let locked = PDFDocument(data: document.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "fixture", PDFDocumentWriteOption.ownerPasswordOption: "owner"])!)!
        presentation.start(document: locked, page: 1) { _ in preconditionFailure("Locked document presented") }
        check(locked.isLocked && presentation.view == nil, "A locked PDF cannot enter slide view")
    }
    check(document.string == originalText && document.page(at: 0)!.annotations.contains { $0 === note && $0.contents == "Pending note" }, "Presentation retains text and pending annotations")
    check(try! Data(contentsOf: source) == originalBytes, "Presentation never rewrites the source PDF")
    window.orderOut(nil)
    print("Passed \(checks) PDF slide checks")
    exit(0)
}
app.run()
