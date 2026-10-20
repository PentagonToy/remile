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
                message = value.reduced ? "\(Int((1 - Double(value.outputBytes) / Double(value.originalBytes)) * 100))% smaller" : settings.grayscale ? "Grayscale ready" : "Already optimized"
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
        panel.nameFieldStringValue = (input?.deletingPathExtension().lastPathComponent ?? "Document") + " compressed.pdf"
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
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Compress").font(.title2.weight(.semibold)); Spacer(); Button("Choose PDF…", action: model.choose).disabled(model.busy || model.saving) }
            HStack(spacing: 18) {
                Picker("Color", selection: $model.settings.grayscale) { Text("Color").tag(false); Text("Grayscale").tag(true) }.pickerStyle(.segmented).frame(width: 240)
                Picker("Quality", selection: $model.settings.quality) { ForEach(CompressionSettings.Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            }.disabled(model.busy || model.saving)
            if let input = model.input { Text(input.lastPathComponent).font(RemileType.heading).lineLimit(1) }
            if let result = model.result, let output = result.batch.outputs.first, let input = model.input {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(result.originalBytes), countStyle: .file) + " → " + ByteCountFormatter.string(fromByteCount: Int64(result.outputBytes), countStyle: .file)).monospacedDigit()
                    Spacer()
                    Picker("Preview", selection: $model.original) { Text("Original").tag(true); Text("Compressed").tag(false) }.pickerStyle(.segmented).frame(width: 240)
                }
                ConversionPreview(url: model.original ? input : output, initialPage: model.previewPage, pageChanged: { model.previewPage = $0 }).id(model.original ? input : output).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ContentUnavailableView(model.busy ? "Compressing…" : "Choose a PDF", systemImage: "arrow.down.right.and.arrow.up.left").frame(maxWidth: .infinity, maxHeight: .infinity) }
            VStack(alignment: .leading, spacing: 6) {
                if model.busy { ProgressView().controlSize(.small); ProgressView(model.stopping ? "Stopping…" : "Compressing · \(model.completed) / \(model.total)", value: Double(model.completed), total: Double(max(1, model.total))) }
                if model.saving { ProgressView("Saving…").controlSize(.small) }
                if let message = model.message { Text(message).font(RemileType.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
            }.frame(minHeight: 36, alignment: .topLeading)
            HStack {
                Button("Close") { dismiss() }.disabled(model.saving)
                Spacer()
                if model.busy { Button("Stop", action: model.stop).disabled(model.stopping) }
                else {
                    Button("Compress", action: model.compress).disabled(model.input == nil || model.saving)
                    Button("Save PDF…", action: model.save).buttonStyle(.borderedProminent).disabled(model.result == nil || model.saving)
                }
            }
        }.padding(24).frame(width: 900, height: 700).background(RemileStyle.background).modifier(ReaderAppearanceModifier())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.busy)
            .onChange(of: model.settings) { _, _ in model.invalidate() }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.busy && !model.saving, urls.count == 1, let url = urls.first, url.pathExtension.lowercased() == "pdf" else { return false }
                model.add(url); return true
            }
            .interactiveDismissDisabled(model.saving).onDisappear { model.close() }
    }
}
