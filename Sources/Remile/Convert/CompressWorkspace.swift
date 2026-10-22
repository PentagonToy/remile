import AppKit
import SwiftUI

@MainActor
final class CompressionModel: ObservableObject {
    @Published var original = false
    @Published var previewPage = 0
    @Published var input: URL?
    @Published var settings = CompressionSettings()
    @Published var result: PDFCompressor.Result?
    @Published var busy = false
    @Published var saving = false
    @Published var stopping = false
    @Published var completed = 0
    @Published var total = 1
    @Published var message: String?
    private let compressor = PDFCompressor()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }
    func add(_ url: URL) {
        guard !busy && !saving else { return }
        invalidate(); previewPage = 0; input = url
    }
    func invalidate() {
        if let result { DocumentConverter.discard(result.batch) }
        result = nil; message = nil
    }
    func compress() {
        guard !busy && !saving, let input else { return }
        invalidate(); busy = true; stopping = false; completed = 0; total = 1
        let token = UUID(); generation = token
        let settings = settings
        task = Task { [self] in
            do {
                let value = try await compressor.prepare(input, settings: settings) { [weak self] done, count in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.busy else { return }
                        self.completed = max(self.completed, done); self.total = count
                    }
                }
                guard !Task.isCancelled, token == generation else { DocumentConverter.discard(value.batch); throw CancellationError() }
                result = value
                message = value.reduced ? "\(Int((1 - Double(value.outputBytes) / Double(value.originalBytes)) * 100))% smaller" : settings.grayscale ? "Greyscale ready" : "Already optimised"
            } catch is CancellationError { if token == generation { message = "Cancelled" } }
            catch { if token == generation { message = error.localizedDescription } }
            if token == generation { busy = false; stopping = false; task = nil }
        }
    }
    func stop() { stopping = true; task?.cancel() }
    func close() { generation = UUID(); task?.cancel(); invalidate() }
    func save() {
        guard let result, !saving else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "compressed_" + (input?.deletingPathExtension().lastPathComponent ?? "Document") + ".pdf"
        guard panel.runModal() == .OK, let destination = panel.url, let source = result.batch.outputs.first else { return }
        guard destination.resolvingSymlinksInPath() != input?.resolvingSymlinksInPath() else { message = "Choose a new filename to keep the original PDF."; return }
        saving = true
        Task {
            do { try await Task.detached { try Data(contentsOf: source).write(to: destination, options: .atomic) }.value; message = "Saved" }
            catch { message = error.localizedDescription }
            saving = false
        }
    }
}

struct CompressWorkspace: View {
    @StateObject private var model: CompressionModel
    @MainActor init() { _model = StateObject(wrappedValue: CompressionModel()) }
    init(model: CompressionModel) { _model = StateObject(wrappedValue: model) }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DocumentToolHeader(title: "Compress PDF", subtitle: "Reduce size and review the result", symbol: "arrow.down.right.and.arrow.up.left")
                if model.input != nil { Button("Change PDF…", action: model.choose).disabled(model.busy || model.saving) }
            }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            Group {
                if model.input == nil {
                    DocumentToolEmptyState(symbols: ["doc.richtext", "arrow.down.right.and.arrow.up.left", "doc"], title: "Give your PDF a lighter footprint", detail: "Drop a PDF here, or choose one below.\nCompare the result before saving.", button: "Choose PDF…", formats: "PDF", choose: model.choose)
                } else { content.padding(24) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }.frame(width: 940, height: 600).background(RemileStyle.background).modifier(ReaderAppearanceModifier())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.busy)
            .onChange(of: model.settings) { _, _ in model.invalidate() }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.busy && !model.saving, urls.count == 1, let url = urls.first, url.pathExtension.lowercased() == "pdf" else { return false }
                model.add(url); return true
            }
            .interactiveDismissDisabled(model.busy || model.saving).onDisappear { model.close() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let input = model.input { Text(input.lastPathComponent).font(RemileType.heading).lineLimit(1).truncationMode(.middle).help(input.lastPathComponent) }
            HStack(spacing: 18) {
                Picker("Colour", selection: $model.settings.grayscale) { Text("Colour").tag(false); Text("Greyscale").tag(true) }.pickerStyle(.segmented).frame(width: 240)
                Picker("Quality", selection: $model.settings.quality) { ForEach(CompressionSettings.Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            }.disabled(model.busy || model.saving)
            if let result = model.result, let output = result.batch.outputs.first, let input = model.input {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(result.originalBytes), countStyle: .file) + " → " + ByteCountFormatter.string(fromByteCount: Int64(result.outputBytes), countStyle: .file)).monospacedDigit()
                    Spacer()
                    Picker("Preview", selection: $model.original) { Text("Original").tag(true); Text("Compressed").tag(false) }.pickerStyle(.segmented).frame(width: 240)
                }
                ConversionPreview(url: model.original ? input : output, initialPage: model.previewPage, pageChanged: { model.previewPage = $0 }).id(model.original ? input : output).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.busy {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Preparing a lighter PDF…").font(RemileType.heading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let input = model.input {
                ConversionPreview(url: input, initialPage: model.previewPage, pageChanged: { model.previewPage = $0 }).id(input).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.busy { ProgressView(model.stopping ? "Stopping…" : "Compressing · \(model.completed) / \(model.total)", value: Double(model.completed), total: Double(max(1, model.total))) }
            if let message = model.message { Text(message).font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            HStack(spacing: 12) {
                Button("Close") { dismiss() }.disabled(model.busy || model.saving).keyboardShortcut(.cancelAction)
                if model.saving { ProgressView("Saving…").controlSize(.small) }
                else { Text("Original files stay unchanged").font(RemileType.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.busy { Button("Stop", action: model.stop).disabled(model.stopping) }
                else if model.input != nil {
                    if model.result == nil {
                        Button("Compress", action: model.compress).buttonStyle(.borderedProminent).disabled(model.saving).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Compress Again", action: model.compress).disabled(model.saving)
                        Button("Save PDF…", action: model.save).buttonStyle(.borderedProminent).disabled(model.saving).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(RemileStyle.surface)
    }
}
