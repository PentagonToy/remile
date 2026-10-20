import AppKit
import PDFKit
import Quartz

struct CompressionSettings: Equatable, Sendable {
    enum Quality: String, CaseIterable, Sendable { case small = "Small", balanced = "Balanced", high = "High Quality" }
    var grayscale = false
    var quality = Quality.balanced
}

actor PDFCompressor {
    struct Result: Sendable {
        let batch: ConversionBatch
        let originalBytes: Int
        let outputBytes: Int
        var reduced: Bool { outputBytes < originalBytes }
    }
    enum Failure: LocalizedError {
        case unsupported, invalid, filter
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Unlock the PDF and flatten interactive fields before compression."
            case .invalid: return "Unable to verify the compressed document."
            case .filter: return "The compression filter is unavailable."
            }
        }
    }
    func prepare(_ input: URL, settings: CompressionSettings, temporaryRoot: URL = FileManager.default.temporaryDirectory, progress: @escaping @Sendable (Int, Int) -> Void) throws -> Result {
        let scope = input.startAccessingSecurityScopedResource()
        defer { if scope { input.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let original = try Data(contentsOf: input)
        guard let document = PDFDocument(data: original), !document.isEncrypted, document.pageCount > 0 else { throw Failure.unsupported }
        if let catalog = document.documentRef?.catalog {
            var value: CGPDFObjectRef?
            for key in ["AcroForm", "Perms"] where CGPDFDictionaryGetObject(catalog, key, &value) { throw Failure.unsupported }
        }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw Failure.invalid }
            if let dictionary = page.pageRef?.dictionary {
                var annotations: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations {
                    for position in 0..<CGPDFArrayGetCount(annotations) {
                        var annotation: CGPDFDictionaryRef?
                        guard CGPDFArrayGetDictionary(annotations, position, &annotation), let annotation else { throw Failure.unsupported }
                        var relation: CGPDFObjectRef?
                        if CGPDFDictionaryGetObject(annotation, "IRT", &relation) { throw Failure.unsupported }
                    }
                }
            } else { throw Failure.invalid }
            for annotation in page.annotations {
                if annotation.type == "Widget" { throw Failure.unsupported }
            }
        }
        var properties: [String: Any] = ["Domains": ["Applications": true], "FilterType": 1, "Name": "Remile"]
        if settings.grayscale {
            guard let profile = NSDictionary(contentsOfFile: "/System/Library/Filters/Gray Tone.qfilter") as? [String: Any] else { throw Failure.filter }
            properties = profile
        }
        let parameters: (Double, Int, Int)
        switch settings.quality {
        case .small: parameters = (0.45, 96, 1600)
        case .balanced: parameters = (0.65, 150, 2400)
        case .high: parameters = (0.85, 300, 4800)
        }
        var data = properties["FilterData"] as? [String: Any] ?? [:]
        var color = data["ColorSettings"] as? [String: Any] ?? [:]
        color["ImageSettings"] = ["Compression Quality": parameters.0, "ImageCompression": "ImageJPEGCompress", "ImageScaleSettings": ["ImageResolution": parameters.1, "ImageScaleInterpolate": true, "ImageSizeMax": parameters.2, "ImageSizeMin": 0]]
        data["ColorSettings"] = color; properties["FilterData"] = data
        guard let filter = QuartzFilter(properties: properties) else { throw Failure.filter }
        let count = document.pageCount
        progress(0, count)
        let observer = NotificationCenter.default.addObserver(forName: .PDFDocumentDidEndPageWrite, object: document, queue: nil) { notification in
            let index = (notification.userInfo?[PDFDocumentPageIndexKey] as? NSNumber)?.intValue ?? 0
            progress(min(count, index + 1), count)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        guard let filtered = document.dataRepresentation(options: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else { throw Failure.invalid }
        var candidates = [filtered]
        if !settings.grayscale {
            var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
            if settings.quality != .high { options[.optimizeImagesForScreenOption] = true }
            if let native = document.dataRepresentation(options: options) { candidates.append(native) }
        }
        var bytes = candidates.min(by: { $0.count < $1.count }) ?? filtered
        try Task.checkCancellation()
        guard let check = PDFDocument(data: bytes), check.pageCount == count else { throw Failure.invalid }
        for index in 0..<count {
            try Task.checkCancellation()
            guard let before = document.page(at: index), let after = check.page(at: index), before.string == after.string,
                  before.bounds(for: .mediaBox) == after.bounds(for: .mediaBox), before.bounds(for: .cropBox) == after.bounds(for: .cropBox), before.rotation == after.rotation,
                  before.annotations.count == after.annotations.count,
                  zip(before.annotations, after.annotations).allSatisfy({ $0.type == $1.type && $0.contents == $1.contents && $0.bounds == $1.bounds }) else { throw Failure.invalid }
        }
        if !settings.grayscale && bytes.count >= original.count { bytes = original }
        let directory = temporaryRoot.appendingPathComponent("Remile-Compress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let output = directory.appendingPathComponent("compressed.pdf")
            try bytes.write(to: output, options: .atomic)
            try Task.checkCancellation()
            progress(count, count)
            return Result(batch: ConversionBatch(directory: directory, items: [ConversionItem(input: input, kind: "PDF", output: output, message: nil)]), originalBytes: original.count, outputBytes: bytes.count)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
