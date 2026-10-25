import AppKit

/// Reuse the bounded local Word image/shape renderer. Unsupported layout never disappears silently.
@MainActor enum WriterForeignImport {
    static func load(_ url: URL, into model: WriterModel) async throws -> Bool {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32_000_000 else { throw ReferenceFailure("Use a DOCX smaller than 32 MB.") }
        let archive = try WordArchive(Data(contentsOf: url, options: .mappedIfSafe))
        if archive.entries.contains(where: { $0.name == "remile/writer.json" }) { return try WriterArchive.open(url, model: model) }
        let document = try WordXML.parse(archive.read("word/document.xml"))
        guard document.descendants("tbl").isEmpty, document.descendants("headerReference").isEmpty, document.descendants("footerReference").isEmpty else {
            throw ReferenceFailure("This Word layout needs Word or a PDF copy.")
        }
        var attributes: NSDictionary?
        let imported = try await WordImages.load(archive, part: "word/document.xml", attributes: &attributes)
        guard imported.length <= 200_000 else { throw ReferenceFailure("This document is too long for Writer.") }
        let text = NSMutableAttributedString(attributedString: imported)
        var count = 0, bytes = 0, failure: Error?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard let attachment = value as? NSTextAttachment else { return }
            do {
                count += 1
                let image = attachment.image ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image
                guard count <= 20, let image, let tiff = image.tiffRepresentation else { throw ReferenceFailure("A Word object has no readable image.") }
                let prepared = try WriterImage.prepare(tiff)
                bytes += prepared.0.count
                guard bytes <= 10_000_000, let picture = NSImage(data: prepared.0) else { throw ReferenceFailure("This document has too many images.") }
                let scale = min(1, (model.pageSize.width - 112) / max(1, image.size.width), (model.pageSize.height - 136) / max(1, image.size.height))
                picture.size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let replacement = NSTextAttachment(); replacement.image = picture; replacement.bounds = CGRect(origin: .zero, size: picture.size)
                text.addAttribute(.attachment, value: replacement, range: range)
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        model.load(text: text, objects: [], paper: PaperSize.a4.rawValue, landscape: false)
        model.foreignDocument = WriterForeignDocument(archive: archive, text: text)
        return false
    }
}
