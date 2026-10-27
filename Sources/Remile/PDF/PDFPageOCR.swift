import AppKit
import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import Vision

/// Local text extraction with one bounded raster at a time. No live reader objects cross the worker boundary.
enum PDFPageOCR {
    static let maximumBytes = 256 * 1024 * 1024
    static let maximumRasterEdge = 2200

    enum Failure: LocalizedError {
        case invalidPDF, tooLarge, locked, copying, page, rendering, noText, outputLimit
        var errorDescription: String? {
            switch self {
            case .invalidPDF: return "This PDF could not be opened for text recognition."
            case .tooLarge: return "Text recognition supports PDFs up to 256 MB."
            case .outputLimit: return "Recognition stopped at ten million characters. You can copy the text extracted so far."
            case .locked: return "Unlock this PDF before recognising text."
            case .copying: return "This PDF does not allow text extraction."
            case .page: return "This page is no longer available."
            case .rendering: return "This page could not be prepared for recognition."
            case .noText: return "No readable text was found on this page."
            }
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var request: VNRecognizeTextRequest?

        func check() throws {
            lock.lock(); let cancelled = stopped; lock.unlock()
            if cancelled { throw CancellationError() }
            try Task.checkCancellation()
        }

        func register(_ request: VNRecognizeTextRequest) throws {
            lock.lock(); let cancelled = stopped
            if !cancelled { self.request = request }
            lock.unlock()
            if cancelled { request.cancel(); throw CancellationError() }
        }

        func cancel() {
            lock.lock(); stopped = true; let active = request; lock.unlock()
            active?.cancel()
        }
    }

    /// Page numbers are one-based, matching the reader's visible page position.
    static func recognise(data: Data, password: String = "", page: Int) async throws -> String {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw Failure.invalidPDF }
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let cancellation = Cancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try cancellation.check()
                guard let document = PDFDocument(data: data) else { throw Failure.invalidPDF }
                if document.isLocked, !password.isEmpty { _ = document.unlock(withPassword: password) }
                guard !document.isLocked else { throw Failure.locked }
                guard document.allowsCopying else { throw Failure.copying }
                guard page > 0, page <= document.pageCount,
                      let reference = document.page(at: page - 1)?.pageRef else { throw Failure.page }
                let text = try recognise(reference, cancellation: cancellation)
                guard !text.isEmpty else { throw Failure.noText }
                return text
            }
        }
        return try await withTaskCancellationHandler {
            let text = try await worker.value
            try Task.checkCancellation()
            return text
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    struct PageResult: Sendable {
        let page: Int
        let total: Int
        let text: String
        let error: String?
    }

    /// Open an independent PDF once, release each raster before advancing, and publish in page order.
    static func recogniseDocument(data: Data, password: String = "", progress: @escaping @Sendable (PageResult) async -> Void) async throws {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw Failure.invalidPDF }
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let cancellation = Cancellation()
        let worker = Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(data: data) else { throw Failure.invalidPDF }
            if document.isLocked, !password.isEmpty { _ = document.unlock(withPassword: password) }
            guard !document.isLocked else { throw Failure.locked }
            guard document.allowsCopying else { throw Failure.copying }
            guard document.pageCount > 0 else { throw Failure.page }
            var characterCount = 0
            for index in 0..<document.pageCount {
                try cancellation.check()
                let result: PageResult = try autoreleasepool {
                    do {
                        guard let reference = document.page(at: index)?.pageRef else { throw Failure.page }
                        let text = try recognise(reference, cancellation: cancellation)
                        return PageResult(page: index + 1, total: document.pageCount, text: text, error: nil)
                    } catch is CancellationError { throw CancellationError() }
                    catch { return PageResult(page: index + 1, total: document.pageCount, text: "", error: error.localizedDescription) }
                }
                characterCount += result.text.utf16.count
                guard characterCount <= 10_000_000 else { throw Failure.outputLimit }
                try cancellation.check()
                await progress(result)
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
            try Task.checkCancellation()
        } onCancel: { cancellation.cancel(); worker.cancel() }
    }

    private static func recognise(_ reference: CGPDFPage, cancellation: Cancellation) throws -> String {
        try cancellation.check()
        let image = try raster(reference)
        try cancellation.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.006
        try cancellation.register(request)
        defer { request.cancel() }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { try cancellation.check(); throw error }
        try cancellation.check()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// CoreGraphics supplies the crop/rotation transform; the raster stays within a fixed pixel budget.
    static func raster(_ page: CGPDFPage) throws -> CGImage {
        let crop = page.getBoxRect(.cropBox), angle = (Int(page.rotationAngle) % 360 + 360) % 360
        guard crop.origin.x.isFinite, crop.origin.y.isFinite, crop.width.isFinite, crop.height.isFinite,
              crop.width > 0, crop.height > 0, angle % 90 == 0 else { throw Failure.rendering }
        let rotated = angle == 90 || angle == 270
        let size = CGSize(width: rotated ? crop.height : crop.width, height: rotated ? crop.width : crop.height)
        let scale = CGFloat(maximumRasterEdge) / max(size.width, size.height)
        let width = max(1, min(maximumRasterEdge, Int((size.width * scale).rounded())))
        let height = max(1, min(maximumRasterEdge, Int((size.height * scale).rounded())))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.rendering }
        let destination = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(destination)
        context.clip(to: destination)
        // The page transform may centre rather than enlarge a small source box. Scale explicitly before it.
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.clip(to: crop)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw Failure.rendering }
        return image
    }
}

@MainActor
final class PDFPageOCRModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var error: String?
    @Published private(set) var running = false
    @Published private(set) var stopped = false
    @Published private(set) var completedPages = 0
    @Published private(set) var totalPages = 0
    @Published private(set) var failedPages = 0
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func start(data: Data, password: String = "", page: Int) {
        task?.cancel()
        let current = UUID(); generation = current
        text = ""; error = nil; stopped = false; running = true
        task = Task { [weak self] in
            do {
                let recognised = try await PDFPageOCR.recognise(data: data, password: password, page: page)
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.text = recognised; self.running = false; self.task = nil
            } catch {
                guard let self, self.generation == current else { return }
                self.running = false; self.task = nil
                if error is CancellationError { self.stopped = true }
                else { self.error = error.localizedDescription }
            }
        }
    }

    func startDocument(data: Data, password: String = "") {
        task?.cancel()
        let current = UUID(); generation = current
        text = ""; error = nil; stopped = false; running = true
        completedPages = 0; totalPages = 0; failedPages = 0
        task = Task { [weak self] in
            do {
                try await PDFPageOCR.recogniseDocument(data: data, password: password) { [weak self] result in
                    await self?.receive(result, generation: current)
                }
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.running = false; self.task = nil
            } catch {
                guard let self, self.generation == current else { return }
                self.running = false; self.task = nil
                if error is CancellationError { self.stopped = true }
                else { self.error = error.localizedDescription }
            }
        }
    }
    private func receive(_ result: PDFPageOCR.PageResult, generation: UUID) {
        guard self.generation == generation, running else { return }
        completedPages = result.page; totalPages = result.total
        if result.error != nil { failedPages += 1 }
        let body = result.error.map { "Recognition unavailable: " + $0 } ?? (result.text.isEmpty ? "No readable text found." : result.text)
        text += (text.isEmpty ? "" : "\n\n") + "— Page \(result.page) —\n" + body
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        if running { stopped = true }
        running = false
    }
}

struct PDFDocumentOCRSheet: View {
    let data: Data
    var password: String = ""
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PDFPageOCRModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recognise PDF text").font(.title2.weight(.semibold))
                    Text("Entire document · On-device OCR").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { model.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if model.running {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.totalPages == 0 ? "Preparing PDF…" : "Recognising page \(min(model.completedPages + 1, model.totalPages)) of \(model.totalPages)…")
                    Spacer()
                    Button("Stop", action: model.stop)
                }
                if model.totalPages > 0 { ProgressView(value: Double(model.completedPages), total: Double(model.totalPages)) }
            } else {
                HStack {
                    SymbolLabel(model.stopped ? "Stopped after \(model.completedPages) pages" : "\(model.completedPages) pages processed", systemImage: model.stopped ? "pause.circle" : "checkmark.circle")
                    if model.failedPages > 0 { Text("· \(model.failedPages) unavailable").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Try Again") { model.startDocument(data: data, password: password) }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            ScrollView {
                Text(model.text.isEmpty ? (model.running ? "Recognised text will appear here, page by page." : "No text extracted.") : model.text)
                    .font(.system(size: 16)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.frame(maxHeight: .infinity).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            Divider()
            HStack {
                Text("Extracted text only. The PDF is unchanged.").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy Text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.text, forType: .string) }.disabled(model.text.isEmpty)
            }
        }.padding(22).frame(minWidth: 570, idealWidth: 700, minHeight: 460, idealHeight: 600)
            .onAppear { model.startDocument(data: data, password: password) }.onDisappear { model.stop() }
    }
}
