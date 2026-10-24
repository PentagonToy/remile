import AppKit
import Combine
import SwiftUI
import PDFKit

// Unrelated entry points needed by the shared paper picker and equation renderer.
@MainActor final class PDFSession: ObservableObject { func fitPages(to size: CGSize) {} }

@MainActor final class SearchSplitProbe: ObservableObject {
    @Published var ask = false
    var created = 0
    var removed = 0
    weak var view: PDFView?
}
struct SearchSplitFixture: View {
    @ObservedObject var probe: SearchSplitProbe
    let document: PDFDocument
    var body: some View {
        SearchPreviewSplit(askPresented: probe.ask, label: "synthetic search Ask", assistant: {
            Text("Ask").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray.opacity(0.1))
        }, preview: { SearchPDFProbe(probe: probe, document: document) })
    }
}
struct SearchPDFProbe: NSViewRepresentable {
    let probe: SearchSplitProbe
    let document: PDFDocument
    func makeCoordinator() -> SearchSplitProbe { probe }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.document = document; view.autoScales = true
        probe.created += 1; probe.view = view; return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
    static func dismantleNSView(_ view: PDFView, coordinator: SearchSplitProbe) { coordinator.removed += 1; view.document = nil }
}

// Use the system ZIP writer, independent of Writer's own archive implementation.
func writerImportFixture(_ root: URL, name: String, body: String) throws -> URL {
    let directory = root.appendingPathComponent(name + "-parts", isDirectory: true)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("word"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("_rels"), withIntermediateDirectories: true)
    let parts = [
        "_rels/.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"document\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
        "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>",
        "word/document.xml": "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"><w:body>" + body + "<w:sectPr/></w:body></w:document>"
    ]
    for (path, xml) in parts { try Data(xml.utf8).write(to: directory.appendingPathComponent(path)) }
    let destination = root.appendingPathComponent(name + ".docx")
    let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
    zip.arguments = ["-q", "-r", destination.path, "."]; try zip.run(); zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { throw NSError(domain: "WriterFixture", code: 1) }
    return destination
}
