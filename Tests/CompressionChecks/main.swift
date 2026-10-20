import AppKit
import PDFKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    guard condition() else { throw NSError(domain: "CompressionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
    checks += 1
}
func colorDifference(_ url: URL) -> Int {
    let document = PDFDocument(url: url)!
    let page = document.page(at: 0)!
    let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    context.scaleBy(x: 100.0 / 612, y: 100.0 / 792)
    withExtendedLifetime(document) { page.draw(with: .mediaBox, to: context) }
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    return (0..<10000).reduce(0) { $0 + abs(Int(pixels[$1 * 4]) - Int(pixels[$1 * 4 + 1])) + abs(Int(pixels[$1 * 4]) - Int(pixels[$1 * 4 + 2])) }
}
func makeFixture(_ output: URL) {
let bitmap = CGContext(data:nil,width:1800,height:1800,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
let pixels=bitmap.data!.assumingMemoryBound(to:UInt8.self)
var seed: UInt32=17
for i in 0..<(1800*1800) { seed=seed &* 1664525 &+ 1013904223; pixels[i*4]=UInt8(truncatingIfNeeded:seed>>24);pixels[i*4+1]=UInt8(truncatingIfNeeded:seed>>16);pixels[i*4+2]=UInt8(truncatingIfNeeded:seed>>8);pixels[i*4+3]=255 }
var box=CGRect(x:0,y:0,width:612,height:792)
let original = output
let context=CGContext(original as CFURL,mediaBox:&box,nil)!
context.beginPDFPage(nil);context.draw(bitmap.makeImage()!,in:CGRect(x:36,y:100,width:540,height:540));context.textPosition=CGPoint(x:36,y:740);CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:"Searchable sample",attributes:[.font:NSFont.systemFont(ofSize:18)])),context);context.endPDFPage();context.closePDF()

}
func threadFixture(_ output: URL) throws {
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 5 0 R] >>",
        "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (Root) /NM (root) >>",
        "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (Reply) /IRT 4 0 R /RT /R /NM (reply) >>"
    ]
    var pdf = "%PDF-1.4\n", offsets = [0]
    for (index, object) in objects.enumerated() {
        offsets.append(pdf.utf8.count); pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let start = pdf.utf8.count
    pdf += "xref\n0 6\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
    pdf += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
    try Data(pdf.utf8).write(to: output)
}
final class ProgressRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func record(_ done: Int, _ total: Int) { lock.lock(); defer { lock.unlock() }; values.append((done, total)) }
    var valid: Bool { lock.lock(); defer { lock.unlock() }; return values.first?.0 == 0 && values.last?.0 == 2 && values.allSatisfy { $0.1 == 2 && $0.0 >= 0 && $0.0 <= 2 } && zip(values, values.dropFirst()).allSatisfy { $0.0 <= $1.0 } }
}
func runChecks() async throws {
    let input = root.appendingPathComponent("probe-original.pdf")
    makeFixture(input)
    let original = try Data(contentsOf: input)
    let engine = PDFCompressor()
    var sizes: [Int] = []
    for gray in [false, true] {
        for quality in CompressionSettings.Quality.allCases {
            let result = try await engine.prepare(input, settings: CompressionSettings(grayscale: gray, quality: quality), temporaryRoot: root) { _, _ in }
            defer { DocumentConverter.discard(result.batch) }
            let output = result.batch.outputs[0]
            let document = PDFDocument(url: output)!
            try check(result.reduced, "Image-heavy fixture reduces for every preset")
            try check(document.string?.contains("Searchable sample") == true && document.pageCount == 1, "Searchable text and page count survive")
            try check(gray ? colorDifference(output) < 1000 : colorDifference(output) > 1000, "Grayscale changes actual page pixels; Color retains chroma")
            try Data(contentsOf: output).write(to: root.appendingPathComponent("\(gray ? "gray" : "color")-\(quality.rawValue).pdf"), options: .atomic)
            if !gray { sizes.append(result.outputBytes) }
        }
    }
    try check(sizes[0] < sizes[1] && sizes[1] < sizes[2], "Quality presets produce increasing sizes on the independent image fixture")
    let annotated = PDFDocument(url: input)!
    let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 20, height: 20), forType: .text, withProperties: nil)
    note.contents = "Keep this note"; annotated.page(at: 0)!.addAnnotation(note)
    let annotatedURL = root.appendingPathComponent("annotated.pdf")
    try annotated.dataRepresentation()!.write(to: annotatedURL)
    let annotatedResult = try await engine.prepare(annotatedURL, settings: CompressionSettings(), temporaryRoot: root) { _, _ in }
    try check(PDFDocument(url: annotatedResult.batch.outputs[0])!.page(at: 0)!.annotations.contains { $0.contents == "Keep this note" }, "Ordinary note content survives")
    DocumentConverter.discard(annotatedResult.batch)
    let tiny = root.appendingPathComponent("tiny.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(tiny as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
    let tinyResult = try await engine.prepare(tiny, settings: CompressionSettings(), temporaryRoot: root) { _, _ in }
    try check(tinyResult.outputBytes <= tinyResult.originalBytes, "Color output never grows")
    DocumentConverter.discard(tinyResult.batch)
    let unchanged = try Data(contentsOf: input)
    try check(unchanged == original, "Original is unchanged")
    let encrypted = root.appendingPathComponent("encrypted.pdf")
    let document = PDFDocument(url: input)!
    try document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "secret"])!.write(to: encrypted)
    do {
        _ = try await engine.prepare(encrypted, settings: CompressionSettings(), temporaryRoot: root) { _, _ in }
        throw NSError(domain: "CompressionChecks", code: 2)
    } catch PDFCompressor.Failure.unsupported { checks += 1 }
    let form = PDFDocument(url: input)!
    form.page(at: 0)!.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .widget, withProperties: nil))
    let formURL = root.appendingPathComponent("form.pdf")
    try form.dataRepresentation()!.write(to: formURL)
    do {
        _ = try await engine.prepare(formURL, settings: CompressionSettings(), temporaryRoot: root) { _, _ in }
        throw NSError(domain: "CompressionChecks", code: 3)
    } catch PDFCompressor.Failure.unsupported { checks += 1 }
    let thread = root.appendingPathComponent("thread.pdf")
    try threadFixture(thread)
    do {
        _ = try await engine.prepare(thread, settings: CompressionSettings(), temporaryRoot: root) { _, _ in }
        throw NSError(domain: "CompressionChecks", code: 5)
    } catch PDFCompressor.Failure.unsupported { checks += 1 }
    let two = PDFDocument(url: input)!
    two.insert(two.page(at: 0)!.copy() as! PDFPage, at: 1)
    let twoURL = root.appendingPathComponent("two-pages.pdf")
    try two.dataRepresentation()!.write(to: twoURL)
    let record = ProgressRecord()
    let twoResult = try await engine.prepare(twoURL, settings: CompressionSettings(), temporaryRoot: root) { record.record($0, $1) }
    try check(record.valid, "Two-page progress starts at zero, remains bounded and ordered, and reaches completion")
    DocumentConverter.discard(twoResult.batch)
    let cancelled = Task {
        try Task.checkCancellation()
        return try await engine.prepare(input, settings: CompressionSettings(), temporaryRoot: root) { _, _ in }
    }
    cancelled.cancel()
    do { _ = try await cancelled.value; throw NSError(domain: "CompressionChecks", code: 4) }
    catch is CancellationError { checks += 1 }
    print("Passed \(checks) compression checks")
}
Task<Void, Never> {
    do { try await runChecks(); exit(0) }
    catch { print("FAILED: \(error)"); exit(1) }
}
app.run()
