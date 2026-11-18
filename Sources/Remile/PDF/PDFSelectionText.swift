import PDFKit

enum PDFSelectionText {
    /// PDFKit can return line selections whose string getter traps inside CoreGraphics.
    static func string(for selection: PDFSelection, on page: PDFPage) -> String? {
        guard selection.pages.contains(where: { $0 === page }), let source = page.string else { return nil }
        let text = source as NSString
        let count = selection.numberOfTextRanges(on: page)
        guard count > 0, count <= text.length else { return nil }
        var pieces: [String] = []
        for index in 0..<count {
            let range = selection.range(at: index, on: page)
            guard range.location != NSNotFound, range.location >= 0, range.location < text.length,
                  range.length > 0, range.length <= text.length - range.location else { return nil }
            pieces.append(text.substring(with: range))
        }
        return pieces.joined()
    }
}
