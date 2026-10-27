import AppKit
import PDFKit

enum PDFDrawingTool: String, CaseIterable, Identifiable {
    case ink = "Draw", rectangle = "Rectangle", ellipse = "Ellipse"
    var id: Self { self }
    var symbol: String {
        switch self { case .ink: return "pencil.line"; case .rectangle: return "rectangle"; case .ellipse: return "circle" }
    }
    func annotation(points: [CGPoint], on page: PDFPage, color: NSColor) -> PDFAnnotation? {
        guard points.count >= 2, points.count <= 10_000, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let first = points.first, let last = points.last else { return nil }
        let crop = page.bounds(for: .cropBox)
        guard points.allSatisfy({ crop.contains($0) }) else { return nil }
        let rect: CGRect
        if self == .ink {
            let xs = points.map(\.x), ys = points.map(\.y)
            rect = CGRect(x: xs.min()! - 2, y: ys.min()! - 2, width: xs.max()! - xs.min()! + 4, height: ys.max()! - ys.min()! + 4).intersection(crop)
            guard zip(points, points.dropFirst()).contains(where: { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) >= 0.5 }) else { return nil }
        } else {
            rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            guard rect.width >= 2, rect.height >= 2 else { return nil }
        }
        let type: PDFAnnotationSubtype = self == .ink ? .ink : self == .rectangle ? .square : .circle
        let annotation = PDFAnnotation(bounds: rect, forType: type, withProperties: nil)
        annotation.color = color
        let border = PDFBorder(); border.lineWidth = 2; annotation.border = border
        annotation.userName = "Me"; annotation.modificationDate = Date()
        if self == .ink {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: first.x - rect.minX, y: first.y - rect.minY))
            for point in points.dropFirst() { path.line(to: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)) }
            annotation.add(path)
        }
        return annotation
    }
}
