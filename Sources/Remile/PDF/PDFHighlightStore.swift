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
        try PDFEditing.validate(document, annotationsOnly: true)
        let graph = PDFCommentGraph(document: document, sourceData: previous)
        let pieces = try regions.map { region -> (PDFPage, CGRect, String) in
            guard region.page >= 0, let page = document.page(at: region.page) else { throw Failure.selection }
            return (page, region.bounds, region.text)
        }
        for (page, note) in try PDFEditing.highlights(regions: pieces, in: document, color: color) {
            page.addAnnotation(note); graph.add(note, parent: nil)
        }
        let data = try graph.serialize(document)
        try Task.checkCancellation()
        try Self.replace(url: url, expected: expected, data: data)
        return Saved(document: document, previous: previous, digest: Self.digest(data))
    }
    func restore(url: URL, expected: Data, data: Data) throws -> Data {
        try Self.replace(url: url, expected: expected, data: data)
        return Self.digest(data)
    }
    nonisolated static func replace(url: URL, expected: Data, data: Data) throws {
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
