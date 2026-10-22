import SwiftUI
import PDFKit
import ImageIO

/// File previews never replace the compiled document or write to the project.
enum TeXAssetData {
    static func load(root: URL, path: String, configuration: TeXConfiguration) throws -> Data {
        let url = try TeXFileSystem.url(path, root: root)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw TeXFileSystem.Failure(errorDescription: "Preview supports files up to 64 MB.") }
        guard url.pathExtension.lowercased() == "eps" else { return try Data(contentsOf: url) }
        let converter = URL(fileURLWithPath: configuration.directory).appendingPathComponent("epstopdf")
        guard FileManager.default.isExecutableFile(atPath: converter.path) else { throw TeXFileSystem.Failure(errorDescription: "EPS preview needs epstopdf from your TeX installation.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("remile-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: url, to: temporary.appendingPathComponent("image.eps"))
        let process = Process(); process.executableURL = converter; process.currentDirectoryURL = temporary
        process.arguments = ["--restricted", "--outfile=image.pdf", "./image.eps"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = configuration.executablePath
        process.environment = environment; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); throw TeXFileSystem.Failure(errorDescription: "EPS preview timed out.") }
        guard process.terminationStatus == 0 else { throw TeXFileSystem.Failure(errorDescription: "Could not preview this EPS graphic.") }
        let output = temporary.appendingPathComponent("image.pdf")
        guard (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try Data(contentsOf: output)
    }
    static let imagePixelLimit = 4096
    static func document(_ bytes: Data, extension kind: String) -> PDFDocument? {
        if ["pdf", "eps"].contains(kind.lowercased()) { return PDFDocument(data: bytes) }
        if kind.lowercased() == "svg", let image = NSImage(data: bytes), image.size.width > 0, image.size.height > 0 {
            let scale = min(1, CGFloat(imagePixelLimit) / max(image.size.width, image.size.height))
            image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            guard let page = PDFPage(image: image) else { return nil }
            let document = PDFDocument(); document.insert(page, at: 0); return document
        }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: imagePixelLimit, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else { return nil }
        let document = PDFDocument(); document.insert(page, at: 0); return document
    }
}

struct TeXAssetPreview: View {
    @ObservedObject var project: TeXProject
    @StateObject private var state = PreviewState()
    @StateObject private var zoom = ReaderZoom()
    @StateObject private var controller = TeXPDFController()
    private final class PreviewState: ObservableObject { @Published var document: PDFDocument?; @Published var error: String?; @Published var loading = false }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text((project.selected as NSString).lastPathComponent).font(RemileType.caption).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if state.document != nil { ReaderPageControl(current: controller.page, total: controller.pages, go: controller.go); ReaderZoomControls(zoom: zoom) }
            }.buttonStyle(RemileToolStyle()).frame(height: 32).padding(.horizontal, 10).background(RemileStyle.editorBar)
            if state.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let document = state.document { TeXPDFPreview(document: document, zoom: zoom, controller: controller, jump: nil) }
            else {
                ContentUnavailableView {
                    Label("Preview unavailable", systemImage: "doc")
                } description: { Text(state.error ?? "This file has no built-in preview.") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task(id: project.root.path + "/" + project.selected + String(project.fileRevision)) { await load() }
    }
    @MainActor private func load() async {
        state.loading = true; state.document = nil; state.error = nil
        let root = project.root, path = project.selected, configuration = TeXConfiguration.current
        do {
            let worker = Task.detached(priority: .userInitiated) {
                let bytes = try TeXAssetData.load(root: root, path: path, configuration: configuration)
                try Task.checkCancellation()
                return TeXAssetData.document(bytes, extension: (path as NSString).pathExtension)
            }
            let document = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard let document, document.pageCount > 0 else { throw TeXFileSystem.Failure(errorDescription: "This file has no built-in preview.") }
            state.document = document
        } catch is CancellationError { return }
        catch { guard !Task.isCancelled else { return }; state.error = error.localizedDescription }
        state.loading = false
    }
}
