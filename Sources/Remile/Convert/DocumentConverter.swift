import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ConversionItem: Identifiable, Sendable {
    let id = UUID()
    let input: URL
    let kind: String
    let output: URL?
    let message: String?
}
struct ConversionBatch: Sendable {
    let directory: URL
    let items: [ConversionItem]
    var outputs: [URL] { items.compactMap(\.output) }
}

struct ConversionSaveReport: Sendable {
    var saved: [UUID: URL] = [:]
    var errors: [String] = []
}

actor DocumentConverter {
    private let temporaryRoot: URL
    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) { self.temporaryRoot = temporaryRoot }
    enum Failure: LocalizedError {
        case unsupported, empty, attachments, pageLimit
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Unsupported file type."
            case .empty: return "No printable content was found."
            case .attachments: return "Embedded Word objects are not supported."
            case .pageLimit: return "This document is too large for the current converter."
            }
        }
    }

    func prepare(_ inputs: [URL], progress: @Sendable (Int, Int) async -> Void, detail: @escaping @Sendable (String, Double?) -> Void = { _, _ in }) async throws -> ConversionBatch {
        let directory = temporaryRoot.appendingPathComponent("Remile-Convert-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            var items: [ConversionItem] = []
            for (position, url) in inputs.enumerated() {
                try Task.checkCancellation()
                await progress(position, inputs.count)
                detail(url.lastPathComponent, nil)
                let output = directory.appendingPathComponent(UUID().uuidString + ".pdf")
                let scope = url.startAccessingSecurityScopedResource()
                defer { if scope { url.stopAccessingSecurityScopedResource() } }
                do {
                    let kind: String
                    if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                        let source = try String(contentsOf: url, encoding: .utf8)
                        var builder = MarkdownHTML(baseURL: url)
                        let html = try builder.document(source)
                        try await MarkdownPDF.write(html, to: output) { fraction in detail(url.lastPathComponent, fraction) }
                        kind = "Markdown"
                    } else if ["doc", "docx"].contains(url.pathExtension.lowercased()), !(CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) > 0 } ?? false) {
                        try await WordPDF.write(url, to: output) { fraction in detail(url.lastPathComponent, fraction) }
                        kind = "Word"
                    } else { kind = try autoreleasepool { try Self.convert(url, to: output) { fraction in detail(url.lastPathComponent, fraction) } } }
                    let message = kind == "Word" ? "Word layout may change." : nil
                    items.append(ConversionItem(input: url, kind: kind, output: output, message: message))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try? FileManager.default.removeItem(at: output)
                    items.append(ConversionItem(input: url, kind: "Unsupported", output: nil, message: error.localizedDescription))
                }
                await progress(position + 1, inputs.count)
            }
            try Task.checkCancellation()
            return ConversionBatch(directory: directory, items: items)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func discard(_ batch: ConversionBatch) { try? FileManager.default.removeItem(at: batch.directory) }

    private static func convert(_ url: URL, to output: URL, progress: (Double) -> Void) throws -> String {
        // Decode images by content, not a filename whitelist. Each frame becomes a page.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let count = CGImageSourceGetCount(source)
            guard count <= 1000 else { throw Failure.pageLimit }
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
            defer { context.closePDF() }
            for number in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 6000, kCGImageSourceShouldCacheImmediately: true]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, number, options as CFDictionary) else { throw Failure.unsupported }
                    context.beginPDFPage(nil)
                    context.setFillColor(NSColor.white.cgColor); context.fill(box)
                    let scale = min(540 / CGFloat(image.width), 720 / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    context.draw(image, in: CGRect(x: (612 - size.width) / 2, y: (792 - size.height) / 2, width: size.width, height: size.height))
                    context.endPDFPage()
                    progress(Double(number + 1) / Double(count))
                }
            }
            return "Image"
        }
        throw Failure.unsupported
    }

    /// Publish without replacing existing files, using an atomic rename in the destination folder.
    static func save(_ batch: ConversionBatch, to directory: URL, excluding: Set<UUID> = []) -> ConversionSaveReport {
        let scope = directory.startAccessingSecurityScopedResource(); defer { if scope { directory.stopAccessingSecurityScopedResource() } }
        var report = ConversionSaveReport()
        for item in batch.items {
            guard !excluding.contains(item.id), let source = item.output else { continue }
            let stem = item.input.deletingPathExtension().lastPathComponent
            var destination = directory.appendingPathComponent(stem + ".pdf")
            var number = 2
            while FileManager.default.fileExists(atPath: destination.path) { destination = directory.appendingPathComponent("\(stem)-\(number).pdf"); number += 1 }
            let staging = directory.appendingPathComponent(".remile-" + UUID().uuidString + ".pdf")
            do {
                try FileManager.default.copyItem(at: source, to: staging)
                try FileManager.default.moveItem(at: staging, to: destination)
                report.saved[item.id] = destination
            } catch { try? FileManager.default.removeItem(at: staging); report.errors.append(item.input.lastPathComponent + ": " + error.localizedDescription) }
        }
        return report
    }
}
