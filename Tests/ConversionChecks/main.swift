import AppKit
import ImageIO
import UniformTypeIdentifiers

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw NSError(domain: "ConversionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    checks += 1
}
func image(_ url: URL, type: CFString, frames: Int = 1) throws {
    let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type, frames, nil)!
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
func runChecks() async throws {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = folder.appendingPathComponent("Picture.png")
        let jpeg = folder.appendingPathComponent("Picture.jpg")
        let tiff = folder.appendingPathComponent("Frames.tiff")
        let renamed = folder.appendingPathComponent("Really-an-image.docx")
        try image(png, type: UTType.png.identifier as CFString)
        try image(jpeg, type: UTType.jpeg.identifier as CFString)
        try image(tiff, type: UTType.tiff.identifier as CFString, frames: 2)
        try FileManager.default.copyItem(at: png, to: renamed)
        let markdown = folder.appendingPathComponent("Notes.md")
        try "# A heading\n\nA **bold** word and *italic* word.\n\n- First\n- Second\n\n```\nlet x = 1\n```".write(to: markdown, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: markdown)
        let word = root.appendingPathComponent("Simple.docx")
        let unknown = folder.appendingPathComponent("Unknown.bin")
        try Data("unknown bytes".utf8).write(to: unknown)
        let engine = DocumentConverter(temporaryRoot: folder)
        let batch = try await engine.prepare([png, jpeg, tiff, renamed, markdown, word, unknown]) { _, _ in }
        defer { DocumentConverter.discard(batch) }
        try check(batch.items.count == 7 && batch.outputs.count == 6, "Mixed formats report success and failure per file")
        try check(batch.items[0].kind == "Image" && batch.items[1].kind == "Image", "PNG and JPEG mix without matching extensions")
        try check(batch.items[3].kind == "Image", "Image decoder validates contents rather than a renamed extension")
        try check(PDFDocument(url: batch.items[2].output!)?.pageCount == 2, "Multi-frame TIFF becomes multiple pages")
        let rendered = PDFDocument(url: batch.items[4].output!)!
        let text = rendered.string ?? ""
        try check(text.contains("A heading") && text.contains("bold") && !text.contains("**"), "Markdown is rendered, not printed as raw markup")
        try check(text.contains("First") && text.contains("let x = 1"), "Lists and code survive Markdown printing")
        let wordPDF = PDFDocument(url: batch.items[5].output!)!
        try check(wordPDF.string?.contains("A simple Word fixture") == true, "Independent OOXML fixture converts to searchable PDF")
        try check(batch.items[5].message?.contains("may change") == true, "Word fidelity notice is explicit")
        let after = try Data(contentsOf: markdown)
        try check(after == original, "Source Markdown is unchanged")
        let legacy = folder.appendingPathComponent("Legacy.doc")
        let legacyText = NSAttributedString(string: "Legacy Word text", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let legacyBytes = try legacyText.data(from: NSRange(location: 0, length: legacyText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
        try legacyBytes.write(to: legacy)
        let legacyBatch = try await engine.prepare([legacy]) { _, _ in }
        try check(legacyBatch.outputs.count == 1 && PDFDocument(url: legacyBatch.outputs[0])?.string?.contains("Legacy Word text") == true, "Native legacy Word route converts a generated document")
        DocumentConverter.discard(legacyBatch)
        let destination = folder.appendingPathComponent("Saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("Picture.pdf")
        try Data("existing file".utf8).write(to: existing)
        let report = DocumentConverter.save(batch, to: destination)
        try check(report.saved.count == 6 && report.errors.isEmpty, "Save publishes each converted file")
        let existingBytes = try Data(contentsOf: existing)
        try check(existingBytes == Data("existing file".utf8), "Existing output is never overwritten")
        try check(Set(report.saved.values.map(\.lastPathComponent)).count == 6, "Matching basenames get unique output names")
        let repeated = DocumentConverter.save(batch, to: destination, excluding: Set(report.saved.keys))
        try check(repeated.saved.isEmpty, "Retry can skip files already saved")
        let failedSave = DocumentConverter.save(batch, to: folder.appendingPathComponent("Missing"))
        try check(failedSave.saved.isEmpty && failedSave.errors.count == 6, "Destination errors are reported per file")
        let features = folder.appendingPathComponent("Features.md")
        try """
        # Rich Markdown

        | Label | Value |
        | :--- | ---: |
        | Alpha | 42 |

        ![Local picture](Picture.png)

        Inline $x^2 + \\alpha$.

        $$
        \\frac{a+b}{c} = \\sqrt{x_1} + \\sum_{i=1}^{n}i
        $$

        $$
        \\begin{pmatrix}a & b \\\\ c & d\\end{pmatrix}
        $$
        """.write(to: features, atomically: true, encoding: .utf8)
        let rich = try await engine.prepare([features]) { _, _ in }
        try check(rich.outputs.count == 1, "Tables, local images and formulas convert together")
        let richPDF = PDFDocument(url: rich.outputs[0])!
        try check(richPDF.string?.contains("Alpha") == true && richPDF.string?.contains("42") == true, "Table text remains searchable")
        let richThumbnail = richPDF.page(at: 0)!.thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox)
        try check(richThumbnail.size.width > 0, "Rich PDF has a renderable page")
        try Data(contentsOf: rich.outputs[0]).write(to: root.appendingPathComponent("rich-markdown.pdf"))
        DocumentConverter.discard(rich)
        let invalid = ["![Image](missing.png)", "![Remote](https://example.invalid/image.png)", "$$\\unknowncommand{x}$$", "```\nUnclosed fence"]
        for (index, source) in invalid.enumerated() {
            let file = folder.appendingPathComponent("Invalid-\(index).md")
            try source.write(to: file, atomically: true, encoding: .utf8)
            let failure = try await engine.prepare([file]) { _, _ in }
            try check(failure.outputs.isEmpty && failure.items[0].message != nil, "Invalid or nonlocal content fails explicitly")
            DocumentConverter.discard(failure)
        }
        let long = folder.appendingPathComponent("Long.md")
        let source = "# Long document\n\n" + String(repeating: "A paragraph about hydrogen and turbulent combustion, repeated to test pagination.\n\n", count: 250) + "FinalMarkerZirconium"
        try source.write(to: long, atomically: true, encoding: .utf8)
        let paginated = try await engine.prepare([long]) { _, _ in }
        let longPDF = PDFDocument(url: paginated.outputs[0])!
        try check(longPDF.pageCount > 2 && longPDF.page(at: longPDF.pageCount - 1)?.string?.contains("FinalMarkerZirconium") == true, "Long text paginates without losing its final content")
        try check((longPDF.string ?? "").components(separatedBy: "hydrogen").count - 1 == 250, "Pagination preserves text without duplicating hidden page content")
        try Data(contentsOf: paginated.outputs[0]).write(to: root.appendingPathComponent("long-markdown.pdf"))
        DocumentConverter.discard(paginated)
        let cancellation = Task {
            try await engine.prepare([png, markdown]) { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        do { _ = try await cancellation.value; throw NSError(domain: "Cancellation ignored", code: 1) }
        catch is CancellationError { checks += 1 }
        let empty = folder.appendingPathComponent("Empty.md")
        try "".write(to: empty, atomically: true, encoding: .utf8)
        let emptyBatch = try await engine.prepare([empty]) { _, _ in }
        try check(emptyBatch.outputs.isEmpty, "Empty documents fail clearly")
        DocumentConverter.discard(emptyBatch)
        DocumentConverter.discard(batch)
        print("\(checks) conversion checks passed")
}
Task<Void, Never> {
    do { try await runChecks(); exit(0) }
    catch { fputs("Conversion checks failed: \(error)\n", stderr); exit(1) }
}
app.run()
