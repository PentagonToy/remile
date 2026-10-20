import AppKit
import CoreText

let app = NSApplication.shared
let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var checks = 0
func verify(_ value: @autoclosure () -> Bool, _ name: String) {
    precondition(value(), name); checks += 1
}
func makePDF(_ name: String, text: String) -> URL {
    let url = output.appendingPathComponent(name)
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 40, y: 700)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)])), context)
    context.endPDFPage(); context.closePDF()
    return url
}
let first = makePDF("A.pdf", text: "First document")
let second = makePDF("B.pdf", text: "Second document")
let pdf = PDFDocument(url: first)!
let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 24, height: 24), forType: .text, withProperties: nil)
annotation.contents = "Preserve this note"
pdf.page(at: 0)!.addAnnotation(annotation)
try pdf.dataRepresentation()!.write(to: first)
let original = try Data(contentsOf: first)
let combined = output.appendingPathComponent("Combined.pdf")
try DocumentTools.create(.combine, inputs: [first, second], destination: combined)
let result = PDFDocument(url: combined)!
verify(result.pageCount == 2, "Combined page count")
verify(result.page(at: 0)!.string!.contains("First") && result.page(at: 1)!.string!.contains("Second"), "Input page order survives")
verify(result.page(at: 0)!.annotations.contains { $0.contents == "Preserve this note" }, "Page annotation survives")
let after = try Data(contentsOf: first)
verify(after == original, "Source remains unchanged")
let widget = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 30), forType: .widget, withProperties: nil)
pdf.page(at: 0)!.addAnnotation(widget)
let form = output.appendingPathComponent("Form.pdf")
try pdf.dataRepresentation()!.write(to: form)
var rejected = false
let rejectedOutput = output.appendingPathComponent("Rejected.pdf")
do { try DocumentTools.create(.combine, inputs: [form], destination: rejectedOutput) } catch { rejected = true }
verify(rejected && !FileManager.default.fileExists(atPath: rejectedOutput.path), "Forms fail before writing output")
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let image = output.appendingPathComponent("Image.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: image)
let images = output.appendingPathComponent("Images.pdf")
try DocumentTools.create(.images, inputs: [image, image], destination: images)
verify(PDFDocument(url: images)?.pageCount == 2, "Each image creates one page")
let invalid = output.appendingPathComponent("Bad.png")
try Data("not an image".utf8).write(to: invalid)
rejected = false
do { try DocumentTools.create(.images, inputs: [invalid], destination: rejectedOutput) } catch { rejected = true }
verify(rejected && !FileManager.default.fileExists(atPath: rejectedOutput.path), "Bad image leaves no partial output")
if CommandLine.arguments.count > 2, FileManager.default.fileExists(atPath: CommandLine.arguments[2]) {
    rejected = false
    do { try DocumentTools.create(.combine, inputs: [URL(fileURLWithPath: CommandLine.arguments[2])], destination: rejectedOutput) } catch { rejected = true }
    verify(rejected && !FileManager.default.fileExists(atPath: rejectedOutput.path), "Threaded comments are rejected rather than flattened")
}
print("\(checks) document tool checks passed")
