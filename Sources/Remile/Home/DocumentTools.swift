import AppKit
import PDFKit

enum DocumentOperation: Sendable { case images, combine }

enum DocumentTools {
    enum Kind: String { case pdf, markdown }
    static func kind(_ inputs: [URL]) throws -> Kind {
        guard !inputs.isEmpty else { throw Failure.unsupported("the selection") }
        let extensions = inputs.map { $0.pathExtension.lowercased() }
        if extensions.allSatisfy({ $0 == "pdf" }) { return .pdf }
        if extensions.allSatisfy({ ["md", "markdown"].contains($0) }) { return .markdown }
        throw NSError(domain: "Remile", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose PDFs together or Markdown files together."])
    }
    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let name): return "Cannot combine \(name). Unlock the PDF and flatten interactive fields before combining."
            }
        }
    }
    private static func hasReply(_ page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return true }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return false }
        for index in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { return true }
            var relation: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(annotation, "IRT", &relation) { return true }
        }
        return false
    }

    static func create(_ operation: DocumentOperation, inputs: [URL], destination: URL) throws {
        guard !inputs.contains(where: { $0.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }) else { throw CocoaError(.fileWriteFileExists) }
        if operation == .combine, try kind(inputs) == .markdown {
            guard destination.pathExtension.lowercased() == "md" else { throw CocoaError(.fileWriteInvalidFileName) }
            var parts: [String] = []
            for input in inputs {
                try Task.checkCancellation()
                let scope = input.startAccessingSecurityScopedResource(); defer { if scope { input.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: input)
                guard data.count <= 16_000_000, let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                parts.append(text)
            }
            try Data(parts.joined(separator: "\n\n").utf8).write(to: destination, options: .atomic)
            return
        }
        let result = PDFDocument()
        for url in inputs {
            try Task.checkCancellation()
            try autoreleasepool {
                switch operation {
                case .images:
                    guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { throw CocoaError(.fileReadCorruptFile) }
                    result.insert(page, at: result.pageCount)
                case .combine:
                    guard let source = PDFDocument(url: url), !source.isEncrypted, source.allowsCopying else { throw Failure.unsupported(url.lastPathComponent) }
                    if let catalog = source.documentRef?.catalog {
                        var form: CGPDFObjectRef?
                        if CGPDFDictionaryGetObject(catalog, "AcroForm", &form) { throw Failure.unsupported(url.lastPathComponent) }
                    }
                    for number in 0..<source.pageCount {
                        guard let original = source.page(at: number), !hasReply(original), !original.annotations.contains(where: { $0.type == "Widget" }), let page = original.copy() as? PDFPage else { throw Failure.unsupported(url.lastPathComponent) }
                        result.insert(page, at: result.pageCount)
                    }
                }
            }
        }
        guard result.pageCount > 0, let bytes = result.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        try bytes.write(to: destination, options: .atomic)
    }
}
