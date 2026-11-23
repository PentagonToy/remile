import PDFKit

enum PDFSelectionText {
    /// Read separate highlight quads so text between columns is not included in the quote.
    static func quote(for annotation: PDFAnnotation, on page: PDFPage) -> String? {
        guard let points = annotation.quadrilateralPoints, !points.isEmpty,
              points.count.isMultiple(of: 4), points.count <= 16_384 else {
            return page.selection(for: annotation.bounds).flatMap { string(for: $0, on: page) }
        }
        var fragments: [String] = []
        for index in stride(from: 0, to: points.count, by: 4) {
            let quad = points[index..<(index + 4)].map(\.pointValue)
            guard quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  let minX = quad.map(\.x).min(), let maxX = quad.map(\.x).max(),
                  let minY = quad.map(\.y).min(), let maxY = quad.map(\.y).max() else { continue }
            let bounds = CGRect(x: annotation.bounds.minX + minX, y: annotation.bounds.minY + minY,
                                width: maxX - minX, height: maxY - minY)
            if let selection = page.selection(for: bounds),
               let text = string(for: selection, on: page)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty { fragments.append(text) }
        }
        return fragments.isEmpty ? nil : fragments.joined(separator: " ")
    }

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
