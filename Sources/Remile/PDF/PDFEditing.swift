import PDFKit

/// In-memory PDF edits use the existing reply-preserving writer; only the document's Save writes a file.
enum PDFEditing {
    enum Failure: LocalizedError {
        case restricted, encrypted, unsupported, selection, invalid, printing
        var errorDescription: String? {
            switch self {
            case .restricted: return "This PDF does not allow that change."
            case .encrypted: return "Editing encrypted PDFs is not supported."
            case .unsupported: return "This PDF contains forms, signatures or content that cannot be safely edited here."
            case .selection: return "Select text on the page to highlight."
            case .invalid: return "The PDF change could not be verified. No change was kept."
            case .printing: return "This PDF does not allow printing, or a print operation could not be prepared."
            }
        }
    }

    static func validate(_ document: PDFDocument, assembly: Bool = false) throws {
        guard !document.isLocked else { throw Failure.restricted }
        guard !document.isEncrypted else { throw Failure.encrypted }
        guard assembly ? document.allowsDocumentAssembly : document.allowsCommenting else { throw Failure.restricted }
        guard document.pageCount > 0, let catalog = document.documentRef?.catalog else { throw Failure.unsupported }
        var value: CGPDFObjectRef?
        for key in ["Perms", "Collection"] where CGPDFDictionaryGetObject(catalog, key, &value) { throw Failure.unsupported }
        if CGPDFDictionaryGetObject(catalog, "AcroForm", &value) {
            var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?, flags: CGPDFInteger = 0
            guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
                  CGPDFDictionaryGetArray(form, "Fields", &fields), let fields, CGPDFArrayGetCount(fields) == 0,
                  !CGPDFDictionaryGetObject(form, "XFA", &value) else { throw Failure.unsupported }
            if CGPDFDictionaryGetObject(form, "SigFlags", &value) {
                guard CGPDFDictionaryGetInteger(form, "SigFlags", &flags), flags == 0 else { throw Failure.unsupported }
            }
            // Publisher PDFs often contain only default form fonts and an explicitly empty Fields array.
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), page.rotation % 90 == 0,
                  !page.annotations.contains(where: { ["Widget", "RichMedia", "Movie", "Sound", "3D", "Screen"].contains($0.type ?? "") }) else { throw Failure.unsupported }
        }
    }

    static func rotate(_ page: PDFPage, to rotation: Int, in document: PDFDocument, graph: PDFCommentGraph) throws -> Data {
        try validate(document, assembly: true)
        guard page.document === document, rotation % 90 == 0 else { throw Failure.invalid }
        let previous = page.rotation
        page.rotation = (rotation % 360 + 360) % 360
        do {
            let bytes = try graph.serialize(document)
            guard let check = PDFDocument(data: bytes), check.pageCount == document.pageCount,
                  let checkPage = check.page(at: document.index(for: page)), checkPage.rotation == page.rotation,
                  checkPage.string == page.string else { throw Failure.invalid }
            return bytes
        } catch {
            page.rotation = previous
            throw error
        }
    }

    static func highlights(for selection: PDFSelection, in document: PDFDocument, color: HighlightColor = .yellow) throws -> [(PDFPage, PDFAnnotation)] {
        try validate(document)
        guard document.allowsCopying, !selection.pages.isEmpty,
              selection.pages.allSatisfy({ $0.document === document }) else { throw Failure.selection }
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty, lines.count <= 200 else { throw Failure.selection }
        return try lines.map { line in
            guard line.pages.count == 1, let page = line.pages.first, page.document === document,
                  let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.selection }
            let bounds = line.bounds(for: page)
            guard bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0,
                  page.bounds(for: .mediaBox).insetBy(dx: -1, dy: -1).contains(bounds) else { throw Failure.selection }
            let note = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            let w = bounds.width, h = bounds.height
            note.quadrilateralPoints = [NSPoint(x: 0, y: h), NSPoint(x: w, y: h), NSPoint(x: 0, y: 0), NSPoint(x: w, y: 0)].map { NSValue(point: $0) }
            note.color = color.color.withAlphaComponent(0.30)
            note.userName = "Me"; note.modificationDate = Date()
            return (page, note)
        }
    }

    static func apply(_ highlights: [(PDFPage, PDFAnnotation)], adding: Bool, in document: PDFDocument, graph: PDFCommentGraph) throws -> Data {
        try validate(document)
        guard !highlights.isEmpty, highlights.allSatisfy({ $0.0.document === document }) else { throw Failure.selection }
        for (page, note) in highlights {
            if adding { page.addAnnotation(note); graph.add(note, parent: nil) }
            else { page.removeAnnotation(note); graph.remove(note) }
        }
        do { return try graph.serialize(document) }
        catch {
            for (page, note) in highlights {
                if adding { page.removeAnnotation(note); graph.remove(note) }
                else { page.addAnnotation(note); graph.add(note, parent: nil) }
            }
            throw error
        }
    }
}
