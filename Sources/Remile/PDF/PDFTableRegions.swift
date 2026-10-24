import AppKit
import PDFKit
import Vision

/// Recognition runs only after an explicit page request. Cells may need correction after pasting.
enum PDFTableRegions {
    static func target(in regions: [PDFContentRegions.Region], point: CGPoint, selection: CGRect?) throws -> PDFContentRegions.Region {
        let tables = regions.filter { $0.kind == .table }
        if let selection, PDFContentRegions.valid(selection) {
            let overlaps = tables.map { table -> (PDFContentRegions.Region, CGFloat) in
                let rect = table.bounds.intersection(selection)
                return (table, PDFContentRegions.valid(rect) ? rect.width * rect.height : 0)
            }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            if let best = overlaps.first, overlaps.count == 1 || best.1 > overlaps[1].1 * 1.1 { return best.0 }
        }
        let hits = tables.filter { $0.bounds.insetBy(dx: -3, dy: -3).contains(point) }
        if let table = hits.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) { return table }
        throw PDFContentRegions.Failure("Select a table or right-click inside it.")
    }
    static func recognise(_ snapshot: PDFContentRegions.Snapshot) async throws -> [PDFContentRegions.Region] {
        try Task.checkCancellation()
        guard #available(macOS 26.0, *) else { throw PDFContentRegions.Failure("Table recognition requires macOS 26 or later.") }
        guard let document = PDFDocument(data: snapshot.data), let page = document.page(at: 0), let ref = page.pageRef else { throw PDFContentRegions.Failure("This page could not be read.") }
        let thumbnail = page.thumbnail(of: CGSize(width: 1800, height: 1800), for: .cropBox)
        guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PDFContentRegions.Failure("This page could not be prepared.") }
        let width = image.width, height = image.height
        let transform = PDFContentRegions.displayTransform(ref, pixels: CGSize(width: width, height: height))
        var request = RecognizeDocumentsRequest()
        request.barcodeDetectionOptions.enabled = false
        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
        var result: [PDFContentRegions.Region] = []
        for observation in observations {
            for table in observation.document.tables where result.count < 20 {
                let rowCount = table.rows.count, columnCount = table.columns.count
                guard rowCount > 1, rowCount <= 500, columnCount > 1, columnCount <= 50 else { continue }
                let normal = table.boundingRegion.normalizedPath.boundingBox
                let pixels = CGRect(x: normal.minX * CGFloat(width), y: normal.minY * CGFloat(height), width: normal.width * CGFloat(width), height: normal.height * CGFloat(height))
                let bounds = pixels.applying(transform.inverted()).intersection(snapshot.bounds)
                guard PDFContentRegions.valid(bounds) else { continue }
                var rows = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
                let cells = table.rows.flatMap { $0 }
                let firstRow = cells.map { $0.rowRange.lowerBound }.min() ?? 0
                let firstColumn = cells.map { $0.columnRange.lowerBound }.min() ?? 0
                for cell in cells {
                    let r = cell.rowRange.lowerBound - firstRow, c = cell.columnRange.lowerBound - firstColumn
                    guard rows.indices.contains(r), rows[r].indices.contains(c) else { continue }
                    rows[r][c] = cell.content.text.transcript
                }
                result.append(.init(id: "table-\(result.count + 1)", kind: .table, bounds: bounds, rows: rows, source: "apple-vision"))
            }
        }
        return result.sorted { a, b in
            a.bounds.maxY != b.bounds.maxY ? a.bounds.maxY > b.bounds.maxY : a.bounds.minX < b.bounds.minX
        }.enumerated().map { index, region in
            PDFContentRegions.Region(id: "table-\(index + 1)", kind: .table, bounds: region.bounds, rows: region.rows, source: region.source)
        }
    }
}
