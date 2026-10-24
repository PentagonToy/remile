import AppKit
import PDFKit

/// Regions use unrotated PDF page coordinates. Rendering and PDFView own display conversion.
enum PDFContentRegions {
    struct Region: Sendable {
        enum Kind: String, Sendable { case image, table }
        let id: String
        let kind: Kind
        let bounds: CGRect
        var rows: [[String]] = []
        var source = "pdf-objects"
        var pixelWidth: Int? = nil
        var pixelHeight: Int? = nil
        var tsv: String { rows.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }.joined(separator: "\n") }
    }
    struct Snapshot: Sendable {
        let data: Data
        let bounds: CGRect
        let rotation: Int
        init(_ page: PDFPage) throws {
            guard let document = page.document, !document.isLocked, document.allowsCopying else { throw Failure("This PDF does not allow copying.") }
            let bounds = page.bounds(for: .cropBox)
            guard valid(bounds), bounds.width <= 20_000, bounds.height <= 20_000,
                  let data = page.dataRepresentation, data.count <= 32 * 1024 * 1024 else { throw Failure("This page is too large to inspect.") }
            self.data = data; self.bounds = bounds; rotation = page.rotation
        }

    }
    struct Failure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }
    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && !rect.isNull && rect.width > 0 && rect.height > 0
    }
    static func imageBounds(at point: CGPoint, on page: PDFPage) -> CGRect? {
        guard let document = page.document, !document.isLocked, document.allowsCopying, let reference = page.pageRef else { return nil }
        return PDFImageRegions.scan(reference).images.filter { $0.bounds.contains(point) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }?.bounds
    }
    static func native(_ snapshot: Snapshot) throws -> [Region] {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: snapshot.data), let page = document.page(at: 0), let reference = page.pageRef else { throw Failure("This page could not be read.") }
        let objects = PDFImageRegions.scan(reference)
        let result = objects.images.enumerated().map { index, image in
            Region(id: "image-\(index + 1)", kind: .image, bounds: image.bounds, pixelWidth: image.width, pixelHeight: image.height)
        }
        return result
    }
    static func displayTransform(_ page: CGPDFPage, pixels: CGSize) -> CGAffineTransform {
        let crop = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 != 0
        let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        // Form the page transform at its natural size, then scale explicitly to the raster.
        let natural = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        return natural.concatenating(CGAffineTransform(scaleX: pixels.width / size.width, y: pixels.height / size.height))
    }
    static func png(_ snapshot: Snapshot, bounds: CGRect, maximumEdge: Int = 2200) throws -> Data {
        try Task.checkCancellation()
        guard maximumEdge > 0, maximumEdge <= 4096, let provider = CGDataProvider(data: snapshot.data as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else { throw Failure("This page could not be rendered.") }
        let region = bounds.intersection(page.getBoxRect(.cropBox))
        guard valid(region) else { throw Failure("Choose an area within this page.") }
        // The PDF drawing transform handles crop origins and quarter-turn rotations exactly once.
        let rotated = abs(page.rotationAngle) % 180 != 0
        let size = rotated ? CGSize(width: region.height, height: region.width) : region.size
        let scale = min(2, CGFloat(maximumEdge) / max(size.width, size.height))
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure("This image could not be prepared.") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let crop = page.getBoxRect(.cropBox)
        let pageSize = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        let display = displayTransform(page, pixels: pageSize)
        let displayRegion = region.applying(display)
        let transform = display.concatenating(CGAffineTransform(translationX: -displayRegion.minX, y: -displayRegion.minY)).concatenating(CGAffineTransform(scaleX: scale, y: scale))
        context.concatenate(transform); context.drawPDFPage(page)
        guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure("This image could not be copied.") }
        return png
    }
    static func markdown(_ tsv: String) -> String {
        var rows = tsv.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        while rows.last?.allSatisfy({ $0.isEmpty }) == true { rows.removeLast() }
        guard let count = rows.map(\.count).max(), count > 0 else { return "" }
        let lines = rows.map { row in "| " + (row + Array(repeating: "", count: count - row.count)).map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
        return ([lines[0], "| " + Array(repeating: "---", count: count).joined(separator: " | ") + " |"] + lines.dropFirst()).joined(separator: "\n")
    }
}
