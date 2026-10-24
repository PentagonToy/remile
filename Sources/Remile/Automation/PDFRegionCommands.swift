import AppKit
import PDFKit
import CryptoKit

/// CLI and reader menus share page inspection, recognition and rendering.
@MainActor
enum PDFRegionCommands {
    static func response(path: String, page number: Int, tables: Bool, region identifier: String?, output: String?, expectedHash: String?) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else { throw PDFContentRegions.Failure("Choose a PDF smaller than 512 MB.") }
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expectedHash, expectedHash != hash { throw PDFContentRegions.Failure("The PDF changed. Inspect it again before exporting.") }
        guard let document = PDFDocument(data: data), number > 0, number <= document.pageCount, let page = document.page(at: number - 1) else { throw PDFContentRegions.Failure("Choose an existing PDF page.") }
        let snapshot = try PDFContentRegions.Snapshot(page)
        var regions = try PDFContentRegions.native(snapshot)
        if tables {
            let reply = Reply()
            Task.detached { do { reply.set(.success(try await PDFTableRegions.recognise(snapshot))) } catch { reply.set(.failure(error)) } }
            while reply.value == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            regions += try reply.value!.get()
        }
        var result: [String: Any] = ["ok": true, "path": path, "page": number, "sha256": hash, "coordinates": "PDF page points, bottom-left origin, before rotation", "regions": regions.map { region -> [String: Any] in
            var entry: [String: Any] = ["id": region.id, "kind": region.kind.rawValue, "bounds": ["x": region.bounds.minX, "y": region.bounds.minY, "width": region.bounds.width, "height": region.bounds.height], "source": region.source]
            if region.kind == .table { entry["rows"] = region.rows; entry["needsReview"] = true }
            if let width = region.pixelWidth, let height = region.pixelHeight { entry["pixels"] = [width, height] }
            return entry
        }]
        if identifier != nil || output != nil {
            guard let identifier, let output, expectedHash != nil, let region = regions.first(where: { $0.id == identifier }) else { throw PDFContentRegions.Failure("Provide a region ID, new output path and --expected-sha256 from inspection.") }
            let target = URL(fileURLWithPath: output)
            guard output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output) else { throw PDFContentRegions.Failure("Choose a new absolute output file.") }
            try StorageFileAccess.requireWritable(target)
            let contents: Data
            if region.kind == .image {
                guard target.pathExtension.lowercased() == "png" else { throw PDFContentRegions.Failure("Use .png for an image.") }
                contents = try PDFContentRegions.png(snapshot, bounds: region.bounds)
            } else {
                guard ["tsv", "md"].contains(target.pathExtension.lowercased()) else { throw PDFContentRegions.Failure("Use .tsv or .md for a table.") }
                contents = Data((target.pathExtension.lowercased() == "md" ? PDFContentRegions.markdown(region.tsv) : region.tsv).utf8)
            }
            try contents.write(to: target, options: .withoutOverwriting)
            result["output"] = output
        }
        return result
    }
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<[PDFContentRegions.Region], Error>?
        var value: Result<[PDFContentRegions.Region], Error>? { lock.lock(); defer { lock.unlock() }; return result }
        func set(_ value: Result<[PDFContentRegions.Region], Error>) { lock.lock(); result = value; lock.unlock() }
    }
}
