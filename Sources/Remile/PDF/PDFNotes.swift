import PDFKit

// Keep the mutation and serialisation boundary together: a failed save rolls back the note.
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
        guard !document.isLocked, document.allowsCommenting else { throw Failure.restricted }
        guard !document.isEncrypted else { throw Failure.encrypted }
        guard page.document === document, parent == nil || parent?.page === page else { throw Failure.invalidParent }
        if adding { page.addAnnotation(note) } else { page.removeAnnotation(note) }
        if adding { graph.add(note, parent: parent) } else { graph.remove(note) }
        do {
            return try graph.serialize(document)
        } catch {
            if adding { page.removeAnnotation(note) } else { page.addAnnotation(note) }
            if adding { graph.remove(note) } else { graph.add(note, parent: parent) }
            throw error
        }
    }
}
