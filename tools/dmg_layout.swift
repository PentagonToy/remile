import AppKit

// A small, single-leaf Finder store; no Finder scripting or package dependency.
// Format reference: https://github.com/dmgbuild/ds_store
private func uint32(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
private func plist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
}
private struct Record {
    let name: String, code: String, type: String
    let value: Data
    var encoded: Data {
        var data = uint32(UInt32(name.utf16.count))
        data += name.data(using: .utf16BigEndian)!
        data += Data(code.utf8); data += Data(type.utf8)
        if type == "blob" { data += uint32(UInt32(value.count)) }
        data += value
        return data
    }
}
private func store(at url: URL, alias: Data) throws {
    // Allow for title/path bars even when Finder keeps its global bar preference.
    let window: [String: Any] = [
        "WindowBounds": "{{300, 180}, {700, 490}}",
        "ShowToolbar": false, "ShowStatusBar": false, "ShowPathbar": false,
        "ShowSidebar": false, "ContainerShowSidebar": false, "ShowTabView": false,
        "PreviewPaneVisibility": false, "SidebarWidth": 0,
    ]
    let icons: [String: Any] = [
        "viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": alias,
        "backgroundColorRed": 243.0 / 255, "backgroundColorGreen": 239.0 / 255,
        "backgroundColorBlue": 231.0 / 255, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "gridSpacing": 100.0, "arrangeBy": "none", "showIconPreview": false,
        "showItemInfo": false, "labelOnBottom": true, "textSize": 13.0,
        "iconSize": 112.0, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    ]
    func location(_ x: UInt32, _ y: UInt32) -> Data { uint32(x) + uint32(y) + uint32(0xffffffff) + uint32(0xffff0000) }
    let records = [
        Record(name: ".", code: "bwsp", type: "blob", value: try plist(window)),
        Record(name: ".", code: "icvp", type: "blob", value: try plist(icons)),
        Record(name: ".", code: "vSrn", type: "long", value: uint32(1)),
        Record(name: ".", code: "icvl", type: "type", value: Data("icnv".utf8)),
        Record(name: "Applications", code: "Iloc", type: "blob", value: location(520, 195)),
        Record(name: "remile.app", code: "Iloc", type: "blob", value: location(180, 195)),
    ].sorted {
        let order = $0.name.lowercased().compare($1.name.lowercased())
        return order == .orderedSame ? $0.code < $1.code : order == .orderedAscending
    }
    // Finder's conventional store uses an 8 KiB allocation for a 4 KiB leaf page.
    var root = uint32(3) + uint32(0)
    root += uint32(2048 | 11) + uint32(32 | 5) + uint32(8192 | 13)
    root += Data(count: 253 * 4)
    root += uint32(1) + Data([4]) + Data("DSDB".utf8) + uint32(1)
    for width in 0..<32 {
        let free = (6...10).contains(width) || width == 12 || (14...30).contains(width)
        root += uint32(free ? 1 : 0)
        if free { root += uint32(UInt32(1) << width) }
    }
    var leaf = uint32(0) + uint32(UInt32(records.count))
    for record in records { leaf += record.encoded }
    guard root.count <= 2048, leaf.count <= 4096 else { throw CocoaError(.fileWriteOutOfSpace) }
    var file = Data(count: 16388)
    var header = uint32(1) + Data("Bud1".utf8) + uint32(2048) + uint32(2048) + uint32(2048)
    header += Data([0, 0, 0x10, 0x0c, 0, 0, 0, 0x87, 0, 0, 0x20, 0x0b, 0, 0, 0, 0])
    file.replaceSubrange(0..<header.count, with: header)
    // Levels count edges below the root; a leaf root must be level zero.
    let master = uint32(2) + uint32(0) + uint32(UInt32(records.count)) + uint32(1) + uint32(4096)
    file.replaceSubrange(36..<(36 + master.count), with: master)
    file.replaceSubrange(2052..<(2052 + root.count), with: root)
    file.replaceSubrange(8196..<(8196 + leaf.count), with: leaf)
    try file.write(to: url, options: .atomic)
}
private func background(at url: URL) throws {
    let size = NSSize(width: 700, height: 430)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 860, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: 2, y: 2)
    NSColor(srgbRed: 243 / 255, green: 239 / 255, blue: 231 / 255, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    let arrow = NSBezierPath(); arrow.lineWidth = 4; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 326, y: 235)); arrow.line(to: NSPoint(x: 374, y: 235))
    arrow.move(to: NSPoint(x: 361, y: 248)); arrow.line(to: NSPoint(x: 374, y: 235)); arrow.line(to: NSPoint(x: 361, y: 222))
    NSColor(srgbRed: 146 / 255, green: 107 / 255, blue: 50 / 255, alpha: 1).setStroke(); arrow.stroke()
    let instruction = "Drag remile. to Applications" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(srgbRed: 90 / 255, green: 100 / 255, blue: 107 / 255, alpha: 1)]
    let width = instruction.size(withAttributes: attributes).width
    instruction.draw(at: NSPoint(x: (size.width - width) / 2, y: 52), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .tiff, properties: [.compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url, options: .atomic)
}
let args = CommandLine.arguments
if args.count == 3, args[1] == "background" { try background(at: URL(fileURLWithPath: args[2])) }
else if args.count == 4, args[1] == "layout" { try store(at: URL(fileURLWithPath: args[2]).appendingPathComponent(".DS_Store"), alias: Data(contentsOf: URL(fileURLWithPath: args[3]))) }
else { fputs("Use background PATH or layout MOUNT ALIAS_DATA\n", stderr); exit(2) }
