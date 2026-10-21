import PDFKit

// Share object mutations between deferred reader edits and immediate exports with rollback.
enum PDFNotes {
    enum Failure: LocalizedError {
        case restricted, encrypted, invalidParent
        var errorDescription: String? {
            switch self {
            case .restricted: return "This PDF does not allow comments."
            case .encrypted: return "Editing encrypted PDFs is not supported yet."
            case .invalidParent: return "The comment and its reply must belong to the same PDF page."
            }
        }
    }

    static func make(text: String, author: String, bounds: CGRect) -> PDFAnnotation {
        let note = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        note.contents = text
        note.userName = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Me" : author
        note.modificationDate = Date()
        note.color = .systemYellow
        return note
    }

    static func apply(_ note: PDFAnnotation, on page: PDFPage, in document: PDFDocument, adding: Bool,
                      graph: PDFCommentGraph, parent: PDFAnnotation? = nil) throws -> Data {
        try apply([(note, page, parent)], in: document, adding: adding, graph: graph)
    }

    static func apply(_ changes: [(note: PDFAnnotation, page: PDFPage, parent: PDFAnnotation?)], in document: PDFDocument, adding: Bool, graph: PDFCommentGraph) throws -> Data {
        try change(changes, in: document, adding: adding, graph: graph)
        do { return try graph.serialize(document) }
        catch { try? change(changes, in: document, adding: !adding, graph: graph); throw error }
    }

    /// Interactive reader edits keep annotation objects only. Serialisation is deferred until Save.
    static func change(_ changes: [(note: PDFAnnotation, page: PDFPage, parent: PDFAnnotation?)], in document: PDFDocument, adding: Bool, graph: PDFCommentGraph) throws {
        guard !document.isLocked, document.allowsCommenting else { throw Failure.restricted }
        guard !document.isEncrypted else { throw Failure.encrypted }
        guard !changes.isEmpty else { throw Failure.invalidParent }
        for change in changes {
            guard change.page.document === document else { throw Failure.invalidParent }
            if let parent = change.parent {
                guard parent.page === change.page || (adding && changes.contains { $0.note === parent && $0.page === change.page }) else { throw Failure.invalidParent }
            }
        }
        let ordered = adding ? changes : Array(changes.reversed())
        for (note, page, parent) in ordered {
            if adding { page.addAnnotation(note); graph.add(note, parent: parent) }
            else { page.removeAnnotation(note); graph.remove(note) }
        }
    }
}
