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
        let note = RemileNoteAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        note.contents = text
        note.userName = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Me" : author
        note.modificationDate = Date()
        note.iconType = .comment
        note.color = NSColor(calibratedRed: 0.76, green: 0.60, blue: 0.33, alpha: 1)
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

/// Keep standard Text annotation metadata and hit targets, with a quiet reader appearance.
final class RemileNoteAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 24, y: rect.height / 24)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 5))
        path.addLine(to: CGPoint(x: 5, y: 1))
        path.addLine(to: CGPoint(x: 10, y: 5))
        path.addLine(to: CGPoint(x: 19, y: 5))
        path.addQuadCurve(to: CGPoint(x: 22, y: 8), control: CGPoint(x: 22, y: 5))
        path.addLine(to: CGPoint(x: 22, y: 19))
        path.addQuadCurve(to: CGPoint(x: 19, y: 22), control: CGPoint(x: 22, y: 22))
        path.addLine(to: CGPoint(x: 5, y: 22))
        path.addQuadCurve(to: CGPoint(x: 2, y: 19), control: CGPoint(x: 2, y: 22))
        path.addLine(to: CGPoint(x: 2, y: 8))
        path.addQuadCurve(to: CGPoint(x: 5, y: 5), control: CGPoint(x: 2, y: 5))
        path.closeSubpath()
        context.setFillColor(NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.21, alpha: 0.96).cgColor)
        context.setStrokeColor(NSColor(calibratedRed: 0.76, green: 0.60, blue: 0.33, alpha: 1).cgColor)
        context.setLineWidth(1.3); context.setLineJoin(.round); context.setLineCap(.round)
        context.addPath(path); context.drawPath(using: .fillStroke)
        context.move(to: CGPoint(x: 7, y: 16)); context.addLine(to: CGPoint(x: 17, y: 16))
        context.move(to: CGPoint(x: 7, y: 11)); context.addLine(to: CGPoint(x: 14, y: 11))
        context.strokePath()
        context.restoreGState()
    }
}
