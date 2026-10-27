import AppKit
import PDFKit

/// Recent bitmap thumbnails are shared across sidebar toggles, without retaining PDF pages.
@MainActor final class PDFThumbnailCache {
    static let shared = PDFThumbnailCache()
    static let byteLimit = 8 * 1024 * 1024
    static let countLimit = 32
    static let widthStep: CGFloat = 8
    private struct Key: Hashable {
        let page: ObjectIdentifier
        let rotation: Int
        let width: Int
        let height: Int
        let revision: String
    }
    private final class Entry {
        weak var page: PDFPage?
        let image: NSImage
        let cost: Int
        var used: UInt64
        init(page: PDFPage, image: NSImage, cost: Int, used: UInt64) { self.page = page; self.image = image; self.cost = cost; self.used = used }
    }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var bytes = 0
    var count: Int { entries.count }
    private func key(_ page: PDFPage, size: CGSize, revision: String) -> Key {
        Key(page: ObjectIdentifier(page), rotation: page.rotation, width: Int(size.width.rounded()), height: Int(size.height.rounded()), revision: revision)
    }
    func image(for page: PDFPage, size: CGSize, revision: String) -> NSImage? {
        let key = key(page, size: size, revision: revision)
        guard let entry = entries[key] else { return nil }
        guard entry.page === page else { remove(key); return nil }
        clock &+= 1; entry.used = clock
        return entry.image
    }
    func insert(_ image: NSImage, for page: PDFPage, size: CGSize, revision: String) {
        for key in entries.keys where entries[key]?.page == nil { remove(key) }
        let key = key(page, size: size, revision: revision)
        remove(key)
        let bitmapCost = image.representations.compactMap { $0 as? NSBitmapImageRep }.reduce(0) { $0 + $1.bytesPerRow * $1.pixelsHigh }
        let cost = max(1, bitmapCost > 0 ? bitmapCost : Int(size.width * 2) * Int(size.height * 2) * 4)
        guard cost <= Self.byteLimit else { return }
        while bytes + cost > Self.byteLimit || entries.count >= Self.countLimit {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { break }
            remove(oldest)
        }
        clock &+= 1; entries[key] = Entry(page: page, image: image, cost: cost, used: clock); bytes += cost
    }
    private func remove(_ key: Key) { if let entry = entries.removeValue(forKey: key) { bytes -= entry.cost } }
}
