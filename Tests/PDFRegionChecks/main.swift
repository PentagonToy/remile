import AppKit
import PDFKit

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}

for rotation in [0, 90, 180, 270] {
    let original = pdfImageFixture(rotation: rotation), doc = PDFDocument(data: original)!, page = doc.page(at: 0)!
    let snapshot = try PDFContentRegions.Snapshot(page)
    expect(page.pageRef === page.pageRef, "Page identity must be stable")
    let raster = PDFContentRegions.displayTransform(page.pageRef!, pixels: CGSize(width: 1390, height: 1800))
    let projected = page.bounds(for: .cropBox).applying(raster)
    expect(abs(projected.minX) < 0.01 && abs(projected.minY) < 0.01, "Raster starts at the crop origin")
    expect(abs(projected.width - 1390) < 0.01 && abs(projected.height - 1800) < 0.01, "Raster mapping scales up explicitly and handles rotation")
    let regions = try PDFContentRegions.native(snapshot)
    expect(regions.count == 2, "Find direct and nested Form images")
    expect(regions[0].bounds == CGRect(x: 80, y: 90, width: 100, height: 50), "Direct transform")
    expect(regions[1].bounds == CGRect(x: 210, y: 142, width: 40, height: 20), "Nested Form matrix")
    for region in regions {
        let png = try PDFContentRegions.png(snapshot, bounds: region.bounds)
        let image = NSBitmapImageRep(data: png)!
        let rotated = rotation % 180 != 0
        expect(image.pixelsWide == Int((rotated ? region.bounds.height : region.bounds.width) * 2), "PNG width")
        expect(image.pixelsHigh == Int((rotated ? region.bounds.width : region.bounds.height) * 2), "PNG height")
        expect(image.bitsPerSample == 8 && image.samplesPerPixel >= 3, "RGB sample format")
        let centre = image.bitmapData! + (image.pixelsHigh / 2) * image.bytesPerRow + (image.pixelsWide / 2) * image.samplesPerPixel
        expect(centre[0] > 240 && centre[1] < 10 && centre[2] < 10, "Crop must contain the red image")
    }
    expect(page.bounds(for: .cropBox) == CGRect(x: 20, y: 30, width: 360, height: 250), "Rendering must preserve original crop")
    expect(page.rotation == rotation, "Rendering must preserve original rotation")
}
let clipped = PDFDocument(data: Data(String(data: pdfImageFixture(rotation: 0), encoding: .utf8)!.replacingOccurrences(of: "/BBox [0 0 40 30]", with: "/BBox [0 0 15 30]").utf8))!
let clippedImages = try PDFContentRegions.native(PDFContentRegions.Snapshot(clipped.page(at: 0)!))
expect(clippedImages[1].bounds == CGRect(x: 210, y: 142, width: 20, height: 20), "Form BBox clips image bounds: \(clippedImages.map(\.bounds))")
expect(PDFContentRegions.markdown("A\tB\n1\t2") == "| A | B |\n| --- | --- |\n| 1 | 2 |", "Markdown table")
expect(PDFContentRegions.markdown("A|B\nC") == "| A\\|B |\n| --- |\n| C |", "Escape Markdown pipes")
expect(PDFContentRegions.markdown("") == "", "Empty table")
let tableA = PDFContentRegions.Region(id: "table-1", kind: .table, bounds: CGRect(x: 10, y: 100, width: 100, height: 80), rows: [["A", "B"], ["1", "2"]])
let tableB = PDFContentRegions.Region(id: "table-2", kind: .table, bounds: CGRect(x: 10, y: 10, width: 100, height: 60), rows: [["C", "D"], ["3", "4"]])
let clickedTable = try PDFTableRegions.target(in: [tableA, tableB], point: CGPoint(x: 20, y: 20), selection: nil)
expect(clickedTable.id == "table-2", "Copy the clicked table, not the first table on the page")
let selectedTable = try PDFTableRegions.target(in: [tableA, tableB], point: CGPoint(x: 0, y: 0), selection: CGRect(x: 10, y: 100, width: 90, height: 70))
expect(selectedTable.id == "table-1", "Selected area identifies the table")
expect(tableA.tsv == "A\tB\n1\t2", "Spreadsheet clipboard preserves rows and columns")
do {
    _ = try PDFTableRegions.target(in: [tableA, tableB], point: CGPoint(x: 300, y: 300), selection: nil)
    fatalError("A click outside the tables must not copy an unrelated table")
} catch { checks += 1 }
print("PDF regions: \(checks) checks passed")
if CommandLine.arguments.count > 1 {
    let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
    let images = try PDFContentRegions.native(PDFContentRegions.Snapshot(document.page(at: 3)!))
    expect(images.count == 2, "Transformer figures")
    let snapshot = try PDFContentRegions.Snapshot(document.page(at: 7)!)
    Task {
        do {
            let tables = try await PDFTableRegions.recognise(snapshot)
            expect(tables.count == 1, "Transformer table")
            expect(tables[0].rows.count >= 10, "Table rows")
            expect(tables[0].bounds.contains(CGPoint(x: 300, y: 600)), "Recognised table maps to actual PDF table coordinates")
            let clicked = try PDFTableRegions.target(in: tables, point: CGPoint(x: 300, y: 600), selection: nil)
            expect(clicked.id == tables[0].id, "A click in the actual table selects it")
            expect(tables[0].rows.map { $0.joined() }.joined().contains("Transformer"), "Table contents")
            print("Real paper: 2 image regions, \(tables.count) table, \(tables[0].rows.count) rows")
            exit(0)
        } catch { print(error); exit(1) }
    }
    RunLoop.main.run()
}
