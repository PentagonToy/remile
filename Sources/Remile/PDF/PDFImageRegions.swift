import CoreGraphics
import Foundation

/// A bounded content-stream walk. No OCR, decoding of full-size bitmaps or page raster is needed for hit testing.
enum PDFImageRegions {
    struct Image { let bounds: CGRect; let width: Int; let height: Int }
    struct Result { var images: [Image] = [] }
    private struct Graphics { var transform = CGAffineTransform.identity; var clip: CGRect }
    private final class Scan {
        var result = Result()
        var state: Graphics
        var stack: [Graphics] = []
        var segments: [(CGPoint, CGPoint)] = []
        var current = CGPoint.zero
        var clipPending = false
        var operations = 0
        var depth = 0
        let table: CGPDFOperatorTableRef
        init(bounds: CGRect, table: CGPDFOperatorTableRef) { state = Graphics(clip: bounds); self.table = table }
        func tick(_ scanner: CGPDFScannerRef) -> Bool {
            operations += 1
            guard operations <= 50_000, !Task.isCancelled else { CGPDFScannerStop(scanner); return false }
            return true
        }
    }
    private static func state(_ pointer: UnsafeMutableRawPointer?) -> Scan { Unmanaged<Scan>.fromOpaque(pointer!).takeUnretainedValue() }
    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values = Array(repeating: CGPDFReal(0), count: count)
        for i in values.indices.reversed() { guard CGPDFScannerPopNumber(scanner, &values[i]) else { return nil } }
        return values.allSatisfy(\.isFinite) ? values : nil
    }
    static func scan(_ page: CGPDFPage) -> Result {
        guard let table = CGPDFOperatorTableCreate() else { return Result() }
        let scan = Scan(bounds: page.getBoxRect(.cropBox), table: table)
        CGPDFOperatorTableSetCallback(table, "q") { scanner, p in let s = PDFImageRegions.state(p); if s.tick(scanner) { if s.stack.count < 128 { s.stack.append(s.state) } else { CGPDFScannerStop(scanner) } } }
        CGPDFOperatorTableSetCallback(table, "Q") { scanner, p in let s = PDFImageRegions.state(p); if s.tick(scanner), let previous = s.stack.popLast() { s.state = previous } }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, p in
            let s = PDFImageRegions.state(p); guard s.tick(scanner), let n = PDFImageRegions.numbers(scanner, 6) else { return }
            s.state.transform = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(s.state.transform)
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, p in
            let s = PDFImageRegions.state(p); guard s.tick(scanner), let n = PDFImageRegions.numbers(scanner, 2) else { return }; s.current = CGPoint(x: n[0], y: n[1]).applying(s.state.transform)
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, p in
            let s = PDFImageRegions.state(p); guard s.tick(scanner), let n = PDFImageRegions.numbers(scanner, 2) else { return }; let next = CGPoint(x: n[0], y: n[1]).applying(s.state.transform)
            if s.segments.count < 1024 { s.segments.append((s.current, next)) }; s.current = next
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, p in
            let s = PDFImageRegions.state(p); guard s.tick(scanner), let n = PDFImageRegions.numbers(scanner, 4) else { return }
            let r = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).applying(s.state.transform)
            if s.segments.count < 1020 { s.segments += [(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)), (CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY))] }
        }
        for name in ["W", "W*"] { CGPDFOperatorTableSetCallback(table, name) { _, p in PDFImageRegions.state(p).clipPending = true } }
        let end: CGPDFOperatorCallback = { scanner, p in
            let s = PDFImageRegions.state(p); guard s.tick(scanner) else { return }
            if s.clipPending, !s.segments.isEmpty {
                let points = s.segments.flatMap { [$0.0, $0.1] }
                let left = points.map(\.x).min()!, right = points.map(\.x).max()!
                let bottom = points.map(\.y).min()!, top = points.map(\.y).max()!
                let box = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
                s.state.clip = s.state.clip.intersection(box)
            }
            s.segments.removeAll(keepingCapacity: true); s.clipPending = false
        }
        for name in ["n", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*"] { CGPDFOperatorTableSetCallback(table, name, end) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, p in
            let s = PDFImageRegions.state(p); guard s.tick(scanner), s.result.images.count < 512 else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let parent = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
            if String(cString: subtype) == "Image" {
                let r = CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.state.transform).intersection(s.state.clip)
                var width = 0, height = 0
                CGPDFDictionaryGetInteger(dict, "Width", &width); CGPDFDictionaryGetInteger(dict, "Height", &height)
                if PDFContentRegions.valid(r), r.width >= 4, r.height >= 4 { s.result.images.append(Image(bounds: r, width: width, height: height)) }
            } else if String(cString: subtype) == "Form", s.depth < 8 {
                s.depth += 1
                let oldState = s.state, oldStack = s.stack, oldSegments = s.segments, oldPoint = s.current, oldClip = s.clipPending
                defer { s.state = oldState; s.stack = oldStack; s.segments = oldSegments; s.current = oldPoint; s.clipPending = oldClip; s.depth -= 1 }
                var matrix: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var n = Array(repeating: CGFloat(0), count: 6)
                    if (0..<6).allSatisfy({ CGPDFArrayGetNumber(matrix, $0, &n[$0]) }) { s.state.transform = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(s.state.transform) }
                }
                var box: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "BBox", &box), let box, CGPDFArrayGetCount(box) == 4 {
                    var n = Array(repeating: CGFloat(0), count: 4)
                    if (0..<4).allSatisfy({ CGPDFArrayGetNumber(box, $0, &n[$0]) }) {
                        s.state.clip = s.state.clip.intersection(CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1]).applying(s.state.transform))
                    }
                }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
                // An absent Form resource dictionary inherits the parent content stream.
                let child = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, parent)
                s.stack = []; s.segments = []; s.clipPending = false
                CGPDFScannerScan(CGPDFScannerCreate(child, s.table, p))
            }
        }
        CGPDFScannerScan(CGPDFScannerCreate(CGPDFContentStreamCreateWithPage(page), table, Unmanaged.passUnretained(scan).toOpaque()))
        return scan.result
    }
}
