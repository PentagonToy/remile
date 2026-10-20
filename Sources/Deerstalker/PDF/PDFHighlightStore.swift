import PDFKit
import CryptoKit

struct HighlightRegion: Sendable {
    let page: Int
    let bounds: CGRect
    let text: String
    static func make(selection: PDFSelection, document: PDFDocument) -> [HighlightRegion] {
        selection.selectionsByLine().compactMap { line in
            guard let page = line.pages.first, page.document === document, let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return HighlightRegion(page: document.index(for: page), bounds: line.bounds(for: page), text: text)
        }
    }
}

/// Search edits are explicit, coordinated transactions against an unchanged source snapshot.
actor PDFHighlightStore {
    // The actor relinquishes this PDF instance after returning it to the main actor.
    struct Saved: @unchecked Sendable { let document: PDFDocument; let previous: Data; let digest: Data }
    enum Failure: LocalizedError {
        case changed, unsupported, selection, tooLarge
        var errorDescription: String? {
            switch self {
            case .changed: return "The PDF changed. Update the Library index and try again."
            case .unsupported: return "This PDF cannot be highlighted here."
            case .selection: return "Select text to highlight."
            case .tooLarge: return "This PDF is too large to edit here."
            }
        }
    }
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    func add(url: URL, expected: Data, regions: [HighlightRegion], color: HighlightColor) throws -> Saved {
        guard !regions.isEmpty && regions.count <= 200 else { throw Failure.selection }
        let previous = try Data(contentsOf: url, options: .mappedIfSafe)
        guard previous.count <= 256_000_000 else { throw Failure.tooLarge }
        guard Self.digest(previous) == expected else { throw Failure.changed }
        guard let document = PDFDocument(data: previous), !document.isEncrypted, document.allowsCommenting else { throw Failure.unsupported }
        if let provider = CGDataProvider(data: previous as CFData), let cg = CGPDFDocument(provider), let catalog = cg.catalog {
            var entry: CGPDFObjectRef?
            guard !CGPDFDictionaryGetObject(catalog, "AcroForm", &entry), !CGPDFDictionaryGetObject(catalog, "Perms", &entry) else { throw Failure.unsupported }
        }
        // Form/signature rewrites need a separate preservation contract.
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), !page.annotations.contains(where: { $0.type == "Widget" }) else { throw Failure.unsupported }
        }
        let graph = PDFCommentGraph(document: document)
        for region in regions {
            guard region.bounds.origin.x.isFinite, region.bounds.origin.y.isFinite, region.bounds.width.isFinite, region.bounds.height.isFinite,
                  region.bounds.width > 0, region.bounds.height > 0, region.page >= 0, let page = document.page(at: region.page),
                  page.bounds(for: .mediaBox).insetBy(dx: -1, dy: -1).contains(region.bounds) else { throw Failure.selection }
            let note = PDFAnnotation(bounds: region.bounds, forType: .highlight, withProperties: nil)
            let w = region.bounds.width, h = region.bounds.height
            note.quadrilateralPoints = [NSPoint(x: 0, y: h), NSPoint(x: w, y: h), NSPoint(x: 0, y: 0), NSPoint(x: w, y: 0)].map { NSValue(point: $0) }
            note.color = color.color.withAlphaComponent(0.30)
            note.contents = region.text; note.userName = "Me"; note.modificationDate = Date()
            page.addAnnotation(note); graph.add(note, parent: nil)
        }
        let data = try graph.serialize(document)
        try Task.checkCancellation()
        try replace(url: url, expected: expected, data: data)
        return Saved(document: document, previous: previous, digest: Self.digest(data))
    }
    func restore(url: URL, expected: Data, data: Data) throws -> Data {
        try replace(url: url, expected: expected, data: data)
        return Self.digest(data)
    }
    private func replace(url: URL, expected: Data, data: Data) throws {
        var coordinationError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                try Task.checkCancellation()
                let current = try Data(contentsOf: coordinated, options: .mappedIfSafe)
                guard Self.digest(current) == expected else { throw Failure.changed }
                try data.write(to: coordinated, options: .atomic)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}
