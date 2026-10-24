import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Import only bounded pixels. Photos float on the page and never alter text flow.
enum WriterImage {
    static func valid(_ data: Data) -> Bool {
        guard data.count <= 5_000_000, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? Int, let height = values[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 1600 && height <= 1600
    }
    static func prepare(_ data: Data) throws -> (Data, CGSize) {
        guard data.count <= 25_000_000, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else { throw ReferenceFailure("Choose an image smaller than 25 MB.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw ReferenceFailure("Could not prepare this image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 5_000_000 else { throw ReferenceFailure("Use a smaller image.") }
        return (output as Data, CGSize(width: image.width, height: image.height))
    }
}

@MainActor extension WriterModel {
    func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max; guard size <= 25_000_000 else { throw ReferenceFailure("Choose an image smaller than 25 MB.") }; try addImage(Data(contentsOf: url)) }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult func pasteImage(_ pasteboard: NSPasteboard, at point: CGPoint? = nil, page: Int? = nil) -> Bool {
        do {
            if let bytes = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { try addImage(bytes, at: point, page: page); return true }
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                guard values.contentType?.conforms(to: .image) == true else { return false }
                guard (values.fileSize ?? Int.max) <= 25_000_000 else { throw ReferenceFailure("Choose an image smaller than 25 MB.") }
                try addImage(Data(contentsOf: url), at: point, page: page); return true
            }
            return false
        } catch { self.error = error.localizedDescription; return true }
    }
    func addImage(_ bytes: Data, at point: CGPoint? = nil, page: Int? = nil) throws {
        let (data, pixels) = try WriterImage.prepare(bytes)
        guard objects.count < 100, objects.filter({ $0.kind == .image }).count < 20, objects.compactMap(\.imageData).reduce(data.count, { $0 + $1.count }) <= 10_000_000 else { throw ReferenceFailure("This document has reached its image limit.") }
        var object = WriterObject(kind: .image); object.imageData = data; object.page = page ?? canvas?.currentPage ?? 0
        let factor = min(1, 300 / pixels.width, 240 / pixels.height)
        object.start = point ?? CGPoint(x: 90, y: 150)
        let width = pixels.width * factor, height = pixels.height * factor
        object.start.x = max(0, min(pageSize.width - width, object.start.x)); object.start.y = max(0, min(pageSize.height - height, object.start.y))
        object.end = CGPoint(x: object.start.x + width, y: object.start.y + height)
        insertObject(object)
    }
}
