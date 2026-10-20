import AppKit
import PDFKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R 8 0 R] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [7 0 R] >>",
    "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /T (Alice) /Contents (Root note) /NM (root) >>",
    "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /T (Bob) /Contents (Same-page reply) /IRT 5 0 R /RT /R /NM (reply) >>",
    "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /T (Carol) /Contents (Other-page reply) /IRT 5 0 R /RT /R /NM (other-reply) >>",
    "<< /Type /Annot /Subtype /Link /Rect [50 20 100 40] /Contents (Link description) /A << /S /URI /URI (https://example.com) >> >>"
]
var source = "%PDF-1.4\n", offsets = [0]
for (index, object) in objects.enumerated() { offsets.append(source.utf8.count); source += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
let start = source.utf8.count
source += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
for offset in offsets.dropFirst() { source += String(format: "%010d 00000 n \n", offset) }
source += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
let input = root.appendingPathComponent("Threaded review.pdf"), original = Data(source.utf8)
try original.write(to: input)
let document = PDFDocument(data: original)!
let archive = try PDFCommentExport.capture(document, name: "/private/local/Threaded review.pdf")
precondition(archive.document == "Threaded review.pdf" && archive.comments.count == 3)
precondition(archive.comments[1].replyTo == archive.comments[0].id && archive.comments[2].replyTo == archive.comments[0].id)
precondition(archive.comments[2].page == 2 && archive.comments[0].author == "Alice")
let again = try PDFCommentExport.capture(document, name: "Threaded review.pdf")
precondition(again.comments.map(\.id) == archive.comments.map(\.id))
let json = try PDFCommentExport.data(archive, format: .json)
let decoded = try JSONDecoder().decode(PDFCommentExport.Archive.self, from: json)
precondition(decoded.comments[2].text == "Other-page reply")
let markdown = String(decoding: try PDFCommentExport.data(archive, format: .markdown), as: UTF8.self)
precondition(markdown.contains("Reply to:") && markdown.contains("Page 2") && !markdown.contains("Link description") && !markdown.contains("/private/local"))
try json.write(to: root.appendingPathComponent("comments.json")); try markdown.write(to: root.appendingPathComponent("comments.md"), atomically: true, encoding: .utf8)
let disk = try Data(contentsOf: input); precondition(disk == original)
let result = try PDFCommentExport.response(archive, format: .json, output: nil)
precondition(result["ok"] as? Bool == true && result["schemaVersion"] as? Int == 1)
var rejected = false
do { _ = try PDFCommentExport.response(archive, format: .json, output: input.path) } catch { rejected = true }
precondition(rejected)
let unsaved = PDFDocument(); let page = PDFPage(); unsaved.insert(page, at: 0)
let graph = PDFCommentGraph(document: unsaved)
let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 20, height: 20), forType: .text, withProperties: nil)
note.contents = "Unsaved note"; page.addAnnotation(note); graph.add(note, parent: nil)
let reply = PDFAnnotation(bounds: note.bounds, forType: .text, withProperties: nil)
reply.contents = "Unsaved reply"; page.addAnnotation(reply); graph.add(reply, parent: note)
let live = try PDFCommentExport.capture(unsaved, name: "Live.pdf", graph: graph)
precondition(live.comments.count == 2 && live.comments[1].replyTo == live.comments[0].id)
print("Passed comment export: page/author/body, stable identifiers, same-page and cross-page replies, Markdown/JSON, link exclusion, path privacy and unchanged original")
print("Passed live export: unsaved notes and replies")
