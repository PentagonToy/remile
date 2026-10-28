import Foundation
import AppKit
import PDFKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let source = NSMutableData()
let consumer = CGDataConsumer(data: source)!
var box = CGRect(x: 0, y: 0, width: 500, height: 700)
let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
context.beginPDFPage(nil)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Linear systems: Ax = b", attributes: [.font: NSFont.systemFont(ofSize: 20)]))
context.textPosition = CGPoint(x: 40, y: 600); CTLineDraw(line, context); context.endPDFPage(); context.closePDF()
let document = PDFDocument(data: source as Data)!
let note = PDFAnnotation(bounds: CGRect(x: 40, y: 580, width: 20, height: 20), forType: .text, withProperties: nil)
note.contents = "Unsaved comment"; document.page(at: 0)!.addAnnotation(note)
let result = try PDFInspection.read(document, page: 1, find: "linear", render: root.appendingPathComponent("page.png").path)
precondition((result["text"] as? String)?.contains("Linear systems") == true)
precondition((result["matches"] as? [[String: Any]])?.count == 1)
precondition((result["annotations"] as? [[String: Any]])?.contains { $0["text"] as? String == "Unsaved comment" } == true)
precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("page.png").path))
for page in [0, 2] { do { _ = try PDFInspection.read(document, page: page); fatalError("invalid page accepted") } catch {} }
do { _ = try PDFInspection.read(document, page: 1, render: root.appendingPathComponent("page.png").path); fatalError("overwrote image") } catch {}
for rotation in [0, 90, 180, 270] {
    let page = document.page(at: 0)!; page.rotation = rotation
    page.setBounds(CGRect(x: 10, y: 20, width: 460, height: 640), for: .cropBox)
    let image = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .cropBox)
    let expected = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let url = root.appendingPathComponent("rotated-\(rotation).png")
    _ = try PDFInspection.read(document, page: 1, render: url.path)
    let actual = try Data(contentsOf: url)
    precondition(actual == expected, "Page export must preserve the existing PNG at every rotation")
}
print("Passed PDF page text, source bounds, live annotation, page image and invalid request checks")
