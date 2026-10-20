import AppKit
import PDFKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    guard condition() else { throw NSError(domain: "WordChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
    checks += 1
}
func runChecks() async throws {
    let source = root.appendingPathComponent("Rich.docx")
    let original = try Data(contentsOf: source)
    let converter = DocumentConverter(temporaryRoot: root)
    let batch = try await converter.prepare([source, root.appendingPathComponent("Long.docx")]) { _, _ in }
    defer { DocumentConverter.discard(batch) }
    try check(batch.outputs.count == 2, "Rich and long Word fixtures convert: \(batch.items.map { $0.message ?? "OK" })")
    let rich = PDFDocument(url: batch.items[0].output!)!
    for (index, item) in batch.items.enumerated() {
        try Data(contentsOf: item.output!).write(to: root.appendingPathComponent(index == 0 ? "rich-word.pdf" : "long-word.pdf"))
    }
    try check(rich.string?.contains("BeforeImageMarker") == true && rich.string?.contains("AfterImageMarker") == true, "Text around image is searchable")
    try check(rich.string?.contains("Hydrogen") == true && rich.string?.contains("4.003") == true, "Table cell text survives")
    try check(abs(rich.page(at: 0)!.bounds(for: .mediaBox).width - 595.3) < 1, "Imported A4 paper width is retained")
    try check(rich.pageCount >= 2 && rich.page(at: 1)?.string?.contains("SecondPageMarker") == true, "Explicit page break is retained")
    let long = PDFDocument(url: batch.items[1].output!)!
    try check(long.pageCount > 2 && long.page(at: long.pageCount - 1)?.string?.contains("FinalWordMarker") == true, "Long document paginates to final content")
    try check((long.string ?? "").components(separatedBy: "hydrogen").count - 1 == 180, "Paragraphs neither duplicate nor disappear")
    try check(!(rich.string ?? "").contains("REMILE"), "Internal image placeholders never reach PDF text")
    let page = rich.page(at: 0)!
    func bounds(_ text: String) -> CGRect { page.selection(for: (page.string! as NSString).range(of: text))!.bounds(for: page) }
    try check(abs(bounds("Element").midY - bounds("Value").midY) < 2 && bounds("Value").minX > bounds("Element").maxX, "Table columns retain their visual positions")
    try check(abs(bounds("Hydrogen").midY - bounds("1.008").midY) < 2, "Table values align with their own rows")
    let context = CGContext(data: nil, width: 600, height: 849, bitsPerComponent: 8, bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.scaleBy(x: 600 / 595.3, y: 849 / 841.9)
    page.draw(with: .mediaBox, to: context)
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let blue = (0..<(600 * 849)).filter { Int(pixels[$0 * 4 + 2]) > Int(pixels[$0 * 4]) + 70 && Int(pixels[$0 * 4 + 2]) > Int(pixels[$0 * 4 + 1]) + 40 }.count
    let brick = (0..<(600 * 849)).filter { Int(pixels[$0 * 4]) > Int(pixels[$0 * 4 + 1]) + 40 && Int(pixels[$0 * 4]) > Int(pixels[$0 * 4 + 2]) + 40 }.count
    try check(blue > 20000, "Embedded picture is visibly rendered, not silently dropped")
    try check(brick > 40, "Original heading colour survives")
    for name in ["Missing", "External", "Floating", "Header", "MissingHeader", "UnknownMath", "OverflowHeader"] {
        let rejected = try await converter.prepare([root.appendingPathComponent(name + ".docx")]) { _, _ in }
        try check(rejected.outputs.isEmpty && rejected.items[0].message != nil, "\(name) content fails explicitly")
        DocumentConverter.discard(rejected)
    }
    let stored = try await converter.prepare([root.appendingPathComponent("Stored.docx")]) { _, _ in }
    try check(stored.outputs.count == 1, "Stored ZIP entries and deflated entries both convert")
    DocumentConverter.discard(stored)
    do { _ = try WordArchive(Data(original.prefix(30))); throw NSError(domain: "Invalid archive accepted", code: 2) }
    catch is WordArchive.Failure { checks += 1 }
    var corrupt = original
    let archive = try WordArchive(original)
    let rewritten = archive.replacing("word/document.xml", with: Data("invalid".utf8))
    corrupt = rewritten
    if let marker = corrupt.range(of: Data("invalid".utf8)) { corrupt[marker.lowerBound] ^= 1 }
    do { _ = try WordArchive(corrupt).read("word/document.xml"); throw NSError(domain: "Invalid CRC accepted", code: 3) }
    catch is WordArchive.Failure { checks += 1 }
    let cancellation = Task {
        try await converter.prepare([root.appendingPathComponent("Long.docx")], progress: { _, _ in }, detail: { _, fraction in if fraction != nil { withUnsafeCurrentTask { $0?.cancel() } } })
    }
    do { _ = try await cancellation.value; throw NSError(domain: "Cancellation ignored", code: 4) }
    catch is CancellationError { checks += 1 }
    let tableBatch = try await converter.prepare([root.appendingPathComponent("LongTable.docx")]) { _, _ in }
    try check(tableBatch.outputs.count == 1, "Long table converts")
    let tablePDF = PDFDocument(url: tableBatch.outputs[0])!
    try check(tablePDF.pageCount >= 3 && tablePDF.string?.contains("ValueMarker99") == true, "Table spans pages to its last row")
    try check((tablePDF.string ?? "").components(separatedBy: "RowMarker").count - 1 == 100 && (tablePDF.string ?? "").components(separatedBy: "ValueMarker").count - 1 == 100, "Table pagination neither loses nor duplicates cell contents")
    try Data(contentsOf: tableBatch.outputs[0]).write(to: root.appendingPathComponent("long-table.pdf"))
    DocumentConverter.discard(tableBatch)
    let linked = NSAttributedString(string: "Open reference", attributes: [.font: NSFont.systemFont(ofSize: 14), .link: URL(string: "https://example.invalid/reference")!])
    let linkedURL = root.appendingPathComponent("linked.pdf")
    try WordPDF.paginate(linked, paper: NSSize(width: 612, height: 792), origin: NSPoint(x: 44, y: 44), available: NSSize(width: 524, height: 704), to: linkedURL) { _ in }
    try check(PDFDocument(url: linkedURL)!.page(at: 0)!.annotations.contains { $0.url?.absoluteString == "https://example.invalid/reference" }, "Imported text links produce clickable PDF annotations")
    let layoutBatch = try await converter.prepare([root.appendingPathComponent("Layout.docx"), root.appendingPathComponent("Equation.docx")]) { _, _ in }
    try check(layoutBatch.outputs.count == 2, "Equations and header/footer layout convert: \(layoutBatch.items.map { $0.message ?? "OK" })")
    let layoutPDF = PDFDocument(url: layoutBatch.items[0].output!)!
    try check(layoutPDF.pageCount == 3, "Furniture and equations retain the forced three-page body")
    for (index, title) in ["FirstHeader", "EvenHeader", "DefaultHeader"].enumerated() {
        let text = layoutPDF.page(at: index)?.string ?? ""
        try check(text.contains(title) && text.contains("Page \(index + 1) of 3"), "Correct header variant and resolved PAGE/NUMPAGES on page \(index + 1)")
        try check(text.contains(["BodyOne", "BodyTwo", "BodyThree"][index]), "Body text remains on its own page")
        try check(!text.contains("REMILE"), "No private field or artwork markers reach output")
    }
    let artPage = layoutPDF.page(at: 0)!
    let artContext = CGContext(data: nil, width: 600, height: 849, bitsPerComponent: 8, bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    artContext.scaleBy(x: 600 / 595.3, y: 849 / 841.9); artPage.draw(with: .mediaBox, to: artContext)
    let artPixels = artContext.data!.assumingMemoryBound(to: UInt8.self)
    let colored = (0..<(600 * 849)).filter { Int(artPixels[$0 * 4]) > Int(artPixels[$0 * 4 + 1]) + 40 && Int(artPixels[$0 * 4]) > Int(artPixels[$0 * 4 + 2]) + 40 }.count
    try Data(contentsOf: layoutBatch.items[0].output!).write(to: root.appendingPathComponent("word-layout.pdf"))
    let previewBlue = (0..<(600 * 849)).filter { Int(artPixels[$0 * 4 + 2]) > Int(artPixels[$0 * 4]) + 70 && Int(artPixels[$0 * 4 + 2]) > Int(artPixels[$0 * 4 + 1]) + 40 }.count
    try check(previewBlue > 5000, "Embedded object uses its existing local raster preview")
    try check(colored > 5000, "Inline shape is visibly rendered")
    try Data(contentsOf: layoutBatch.items[0].output!).write(to: root.appendingPathComponent("word-layout.pdf"))
    DocumentConverter.discard(layoutBatch)
    let mathCases: [(String, String)] = [
        ("<m:f><m:num><m:r><m:t>a</m:t></m:r></m:num><m:den><m:r><m:t>b</m:t></m:r></m:den></m:f>", "mfrac"),
        ("<m:sSubSup><m:e><m:r><m:t>x</m:t></m:r></m:e><m:sub><m:r><m:t>i</m:t></m:r></m:sub><m:sup><m:r><m:t>2</m:t></m:r></m:sup></m:sSubSup>", "msubsup"),
        ("<m:m><m:mr><m:e><m:r><m:t>1</m:t></m:r></m:e><m:e><m:r><m:t>0</m:t></m:r></m:e></m:mr></m:m>", "mtable"),
        ("<m:nary><m:naryPr><m:chr m:val=\"∑\"/></m:naryPr><m:sub><m:r><m:t>i=0</m:t></m:r></m:sub><m:sup><m:r><m:t>n</m:t></m:r></m:sup><m:e><m:r><m:t>x</m:t></m:r></m:e></m:nary>", "munderover"),
        ("<m:acc><m:accPr><m:chr m:val=\"̂\"/></m:accPr><m:e><m:r><m:t>x</m:t></m:r></m:e></m:acc>", "mover")
    ]
    for (source, expected) in mathCases {
        let root = try WordXML.parse(Data(("<m:oMath xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\">" + source + "</m:oMath>").utf8))
        let markup = try WordMath.markup(root)
        try check(markup.contains(expected), "Office Math structure maps to \(expected)")
    }
    let freeform = try await converter.prepare([root.appendingPathComponent("Freeform.docx")]) { _, _ in }
    try check(freeform.outputs.count == 1, "Static cubic freeform drawing converts")
    try Data(contentsOf: freeform.outputs[0]).write(to: root.appendingPathComponent("word-freeform.pdf"))
    DocumentConverter.discard(freeform)
    let cancelledArt = Task { try await WordArt.image("<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>x</mi></math>") }
    cancelledArt.cancel()
    do { _ = try await cancelledArt.value; throw NSError(domain: "Artwork cancellation ignored", code: 8) }
    catch is CancellationError { checks += 1 }
    func equation(_ body: String, integral: String = "subSup", nary: String = "undOvr") throws -> String {
        let node = try WordXML.parse(Data(("<m:oMath xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\">" + body + "</m:oMath>").utf8))
        return try WordMath.markup(node, integralLimits: integral, naryLimits: nary)
    }
    let argument = "<m:e><m:r><m:t>x</m:t></m:r></m:e>"
    let brace = try equation("<m:groupChr>" + argument + "</m:groupChr>")
    try check(brace.contains("<munder>") && brace.contains("⏟"), "Group-character defaults put a stretchy brace below its argument")
    let phantom = try equation("<m:phant>" + argument + "</m:phant>")
    try check(!phantom.contains("mphantom"), "Phantom content is visible by default")
    let hidden = try equation("<m:phant><m:phantPr><m:show m:val=\"0\"/><m:zeroWid/></m:phantPr>" + argument + "</m:phant>")
    try check(hidden.contains("<mphantom>") && hidden.contains("width=\"0\""), "Invisible zero-width content retains its vertical dimensions")
    let emptyShow = try equation("<m:phant><m:phantPr><m:show/></m:phantPr>" + argument + "</m:phant>")
    try check(!emptyShow.contains("mphantom"), "Present boolean without a value applies the specified default")
    let border = try equation("<m:borderBox><m:borderBoxPr><m:hideTop/><m:strikeH/></m:borderBoxPr>" + argument + "</m:borderBox>")
    let borderNode = try WordXML.parse(Data(border.utf8)).descendants("menclose").first!
    let notations = (borderNode.attribute("notation") ?? "").split(separator: " ")
    try check(!notations.contains("top") && notations.contains("bottom") && notations.contains("horizontalstrike"), "Border suppression and strike-through are independent")
    let limits = "<m:sub><m:r><m:t>0</m:t></m:r></m:sub><m:sup><m:r><m:t>1</m:t></m:r></m:sup>" + argument
    let integral = try equation("<m:nary>" + limits + "</m:nary>")
    try check(integral.contains("<msubsup>"), "Integral default limits sit beside the operator")
    let sum = try equation("<m:nary><m:naryPr><m:chr m:val=\"∑\"/></m:naryPr>" + limits + "</m:nary>", nary: "subSup")
    try check(sum.contains("<msubsup>"), "Document n-ary defaults reach equation layout")
    let explicit = try equation("<m:nary><m:naryPr><m:limLoc m:val=\"undOvr\"/></m:naryPr>" + limits + "</m:nary>")
    try check(explicit.contains("<munderover>"), "Local limit placement overrides document settings")
    let emptyLocation = try equation("<m:nary><m:naryPr><m:limLoc/></m:naryPr>" + limits + "</m:nary>")
    try check(emptyLocation.contains("<munderover>"), "Present limit location without value uses its own default")
    let semantic = try await converter.prepare([root.appendingPathComponent("MathSemantics.docx")]) { _, _ in }
    try check(semantic.outputs.count == 1, "Semantic equation fixture converts: \(semantic.items.first?.message ?? "")")
    let semanticPDF = PDFDocument(url: semantic.outputs[0])!
    try check(semanticPDF.pageCount == 1 && semanticPDF.string?.contains("Zero width") == true, "All semantic cases fit their generated page")
    try Data(contentsOf: semantic.outputs[0]).write(to: root.appendingPathComponent("math-semantics.pdf"))
    DocumentConverter.discard(semantic)
    let unchanged = try Data(contentsOf: source)
    try check(original == unchanged, "Source bytes remain unchanged")
    print("Passed \(checks) Word checks")
}
Task<Void, Never> {
    do { try await runChecks(); exit(0) }
    catch { print("FAILED: \(error)"); exit(1) }
}
app.run()
