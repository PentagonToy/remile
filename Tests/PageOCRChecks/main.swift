import AppKit
import CoreText
import PDFKit

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label); checks += 1
}
func rejects(_ label: String, operation: () async throws -> String, matching: (Error) -> Bool) async {
    do { _ = try await operation(); preconditionFailure(label) }
    catch { expect(matching(error), label + ": \(error)") }
}
func image(_ text: String, extra: String = "") -> CGImage {
    let context = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8,
                            bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
    for (value, y) in [(text, 380.0), (extra, 30.0)] where !value.isEmpty {
        let string = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 35), .foregroundColor: NSColor.black])
        context.textPosition = CGPoint(x: 140, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    return context.makeImage()!
}
func fixture() -> Data {
    let bytes = NSMutableData()
    var media = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let context = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &media, nil)!
    for text in ["LOCAL OCR PAGE ONE", "SECOND PAGE PRIVATE"] {
        context.beginPDFPage(nil)
        context.draw(image(text, extra: "OUTSIDE CROP MARKER"), in: media)
        context.endPDFPage()
    }
    context.closePDF()
    let document = PDFDocument(data: bytes as Data)!
    document.page(at: 0)!.setBounds(CGRect(x: 100, y: 100, width: 800, height: 400), for: .cropBox)
    return document.dataRepresentation()!
}

@MainActor
func runChecks() async throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let original = fixture(), source = directory.appendingPathComponent("raster-only.pdf")
    try original.write(to: source)
    let document = PDFDocument(data: original)!
    expect((document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Fixture has raster content only")
    expect(document.pageCount == 2, "Fixture has two independent pages")
    let bitmap = try PDFPageOCR.raster(document.page(at: 0)!.pageRef!)
    try NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("cropped-page.png"))
    expect(bitmap.width == 2200 && bitmap.height == 1100, "Crop box determines bounded raster aspect ratio")
    expect(bitmap.width <= PDFPageOCR.maximumRasterEdge && bitmap.height <= PDFPageOCR.maximumRasterEdge, "Both raster edges stay bounded")
    document.page(at: 0)!.rotation = 90
    let rotatedDocument = PDFDocument(data: document.dataRepresentation()!)!
    let rotated = try PDFPageOCR.raster(rotatedDocument.page(at: 0)!.pageRef!)
    expect(rotated.width == 1100 && rotated.height == 2200, "Page rotation swaps the crop raster dimensions")
    document.page(at: 0)!.rotation = 0
    let text = try await PDFPageOCR.recognise(data: original, page: 1)
    try text.write(to: directory.appendingPathComponent("recognised.txt"), atomically: true, encoding: .utf8)
    expect(text.uppercased().contains("LOCAL OCR PAGE ONE"), "Apple Vision recognises the explicitly selected raster page")
    expect(!text.uppercased().contains("SECOND PAGE"), "Recognition never includes a different page")
    expect(!text.uppercased().contains("OUTSIDE CROP"), "Recognition excludes raster content outside the crop box")
    try text.write(to: directory.appendingPathComponent("recognised.txt"), atomically: true, encoding: .utf8)
    expect((try? Data(contentsOf: source)) == original, "Recognition leaves original PDF bytes unchanged")
    await rejects("Invalid bytes are rejected", operation: { try await PDFPageOCR.recognise(data: Data("invalid".utf8), page: 1) }, matching: { if case PDFPageOCR.Failure.invalidPDF = $0 { return true }; return false })
    for page in [0, -1, 3] {
        await rejects("Out-of-range page is rejected", operation: { try await PDFPageOCR.recognise(data: original, page: page) }, matching: { if case PDFPageOCR.Failure.page = $0 { return true }; return false })
    }
    let encrypted = PDFDocument(data: original)!.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"])!
    await rejects("Locked PDF is rejected", operation: { try await PDFPageOCR.recognise(data: encrypted, page: 1) }, matching: { if case PDFPageOCR.Failure.locked = $0 { return true }; return false })
    await rejects("Wrong unlock password is rejected", operation: { try await PDFPageOCR.recognise(data: encrypted, password: "wrong", page: 1) }, matching: { if case PDFPageOCR.Failure.locked = $0 { return true }; return false })
    let restricted = PDFDocument(data: original)!.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader", PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 0)])!
    let check = PDFDocument(data: restricted)!; _ = check.unlock(withPassword: "reader")
    expect(!check.isLocked && !check.allowsCopying, "Restricted fixture has a denied copy permission after unlock")
    await rejects("Unlocked copy-restricted PDF is rejected", operation: { try await PDFPageOCR.recognise(data: restricted, password: "reader", page: 1) }, matching: { if case PDFPageOCR.Failure.copying = $0 { return true }; return false })
    let cancelled = Task { try await PDFPageOCR.recognise(data: original, page: 1) }
    cancelled.cancel()
    await rejects("Pre-cancelled task cannot publish OCR", operation: { try await cancelled.value }, matching: { $0 is CancellationError })
    let active = Task { try await PDFPageOCR.recognise(data: original, page: 1) }
    try await Task.sleep(nanoseconds: 20_000_000); active.cancel()
    await rejects("In-flight cancellation returns CancellationError", operation: { try await active.value }, matching: { $0 is CancellationError })
    let model = PDFPageOCRModel()
    model.start(data: original, page: 1); model.stop()
    try await Task.sleep(nanoseconds: 600_000_000)
    expect(!model.running && model.stopped && model.text.isEmpty && model.error == nil, "Stopped generation cannot publish a late result or error")
    model.start(data: original, page: 1); model.start(data: Data(), page: 1)
    for _ in 0..<100 where model.running { try await Task.sleep(nanoseconds: 10_000_000) }
    try await Task.sleep(nanoseconds: 300_000_000)
    expect(!model.running && model.error != nil && model.text.isEmpty, "Replacement generation retains only the current error")
    expect((try? Data(contentsOf: source)) == original, "All extraction and cancellation checks preserve source bytes")
    let whole = PDFPageOCRModel()
    whole.startDocument(data: original)
    for _ in 0..<600 where whole.running { try await Task.sleep(nanoseconds: 50_000_000) }
    expect(!whole.running && whole.error == nil && whole.completedPages == 2 && whole.totalPages == 2, "Whole-document OCR completes both pages")
    expect(whole.text.contains("LOCAL OCR PAGE ONE") && whole.text.contains("SECOND PAGE PRIVATE"), "Whole-document OCR includes both independent pages")
    expect(whole.text.contains("— Page 1 —") && whole.text.contains("— Page 2 —"), "Output retains source page boundaries")
    expect(!whole.text.components(separatedBy: "— Page 2 —").first!.contains("OUTSIDE CROP MARKER"), "Crop bounds remain enforced in full-document OCR")
    whole.startDocument(data: original); whole.stop()
    try await Task.sleep(nanoseconds: 400_000_000)
    expect(!whole.running && whole.stopped && whole.text.isEmpty, "Whole-document cancellation prevents late output")
    expect((try? Data(contentsOf: source)) == original, "Full-document OCR leaves source unchanged")
    print("\(checks) page OCR checks passed. Actual local Vision on a synthetic raster-only PDF; no user documents, PDF writes or model downloads.")
}

Task { @MainActor in
    do { try await runChecks(); exit(0) }
    catch { print("OCR checks failed: \(error)"); exit(1) }
}
RunLoop.main.run()
