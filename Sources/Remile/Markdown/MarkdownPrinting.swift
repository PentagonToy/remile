import AppKit
import PDFKit

@MainActor
enum MarkdownPrinting {
    static func run(source: String, fileURL: URL?) async throws {
        let url = fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Untitled.md")
        let worker = Task.detached(priority: .userInitiated) { () throws -> String in
            var renderer = MarkdownHTML(baseURL: url); return try renderer.document(source)
        }
        let html = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remile-print-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Document.pdf")
        try await MarkdownPDF.write(html, to: output)
        guard let document = PDFDocument(url: output), let operation = document.printOperation(for: NSPrintInfo.shared.copy() as? NSPrintInfo, scalingMode: .pageScaleToFit, autoRotate: true) else { throw CocoaError(.fileReadCorruptFile) }
        operation.jobTitle = url.lastPathComponent; operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.run()
    }
}
