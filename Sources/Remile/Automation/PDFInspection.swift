import Foundation
import PDFKit
import AppKit

/// Bounded, read-only page context for an agent, shared by the CLI and live reader.
enum PDFInspection {
    struct Failure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }
    static func read(_ document: PDFDocument, page number: Int, find: String? = nil, render: String? = nil) throws -> [String: Any] {
        guard !document.isLocked, document.allowsCopying else { throw Failure("Unlock a PDF that permits text copying.") }
        guard number >= 1, number <= document.pageCount, let page = document.page(at: number - 1) else { throw Failure("Choose a page from 1 to \(document.pageCount).") }
        let text = page.string ?? "", bounds = page.bounds(for: .cropBox)
        func rect(_ value: CGRect) -> [String: Double] { ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height] }
        var result: [String: Any] = ["ok": true, "page": number, "pages": document.pageCount, "label": page.label ?? "\(number)", "text": String(text.prefix(64_000)), "truncated": text.count > 64_000, "bounds": rect(bounds), "coordinateSystem": "PDF page points, bottom-left origin", "annotations": page.annotations.prefix(500).map { ["type": $0.type ?? "", "text": String(($0.contents ?? "").prefix(4000)), "bounds": rect($0.bounds)] as [String: Any] }]
        if let find, !find.isEmpty {
            guard find.count <= 500 else { throw Failure("Search text must be at most 500 characters.") }
            let source = text as NSString
            var ranges: [[String: Any]] = [], start = 0
            while start < source.length, ranges.count < 100 {
                let match = source.range(of: find, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: source.length - start))
                guard match.location != NSNotFound else { break }
                if let selection = page.selection(for: match) { ranges.append(["startUTF16": match.location, "lengthUTF16": match.length, "bounds": rect(selection.bounds(for: page))]) }
                start = NSMaxRange(match)
            }
            result["matches"] = ranges
        }
        if let render {
            guard render.hasPrefix("/"), URL(fileURLWithPath: render).pathExtension.lowercased() == "png", !FileManager.default.fileExists(atPath: render) else { throw Failure("Choose a new absolute .png path for the page image.") }
            let image = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .cropBox)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure("Could not render this PDF page.") }
            try png.write(to: URL(fileURLWithPath: render), options: .withoutOverwriting); result["image"] = render
        }
        return result
    }
}
