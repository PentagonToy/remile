import AppKit
import PDFKit
import SwiftUI

@MainActor
final class ConversionModel: ObservableObject {
    @Published var inputs: [URL] = []
    @Published var batch: ConversionBatch?
    @Published var selected: UUID?
    @Published var busy = false
    @Published var saving = false
    @Published var activeFile = ""
    @Published var fraction: Double?
    @Published var stopping = false
    @Published var completed = 0
    @Published var total = 0
    @Published var message: String?
    @Published var saved: [UUID: URL] = [:]
    private let converter = DocumentConverter()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var selectedItem: ConversionItem? { batch?.items.first { $0.id == selected } }

    func choose() {
        guard !busy && !saving else { return }
        let panel = NSOpenPanel()
        panel.title = "Convert to PDF"; panel.prompt = "Choose Files"
        panel.message = "Images, Word, Markdown"
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }
    func add(_ urls: [URL]) {
        guard !busy && !saving else { return }
        clearBatch()
        for url in urls where url.isFileURL && !inputs.contains(url) { inputs.append(url) }
        message = nil
    }
    func remove(_ url: URL) {
        guard !busy && !saving else { return }
        clearBatch(); inputs.removeAll { $0 == url }
    }
    private func clearBatch() {
        if let batch { DocumentConverter.discard(batch) }
        batch = nil; selected = nil; saved = [:]
    }
    func convert() {
        guard !busy && !saving && !inputs.isEmpty else { return }
        clearBatch(); busy = true; stopping = false; activeFile = ""; fraction = nil; message = nil; total = inputs.count; completed = 0
        let token = UUID(); generation = token
        let files = inputs
        task = Task { [self] in
            do {
                let result = try await converter.prepare(files, progress: { [weak self] done, count in
                    await self?.progress(done, total: count, generation: token)
                }, detail: { [weak self] name, fraction in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.busy else { return }
                        if self.activeFile != name { self.fraction = nil }
                        self.activeFile = name
                        self.fraction = fraction.map { max(self.fraction ?? 0, $0) }
                    }
                })
                guard !Task.isCancelled && token == generation else { DocumentConverter.discard(result); return }
                batch = result; selected = result.items.first(where: { $0.output != nil })?.id ?? result.items.first?.id
                message = "\(result.outputs.count) ready" + (result.items.count > result.outputs.count ? " · \(result.items.count - result.outputs.count) failed" : "")
            } catch is CancellationError {
                if token == generation { message = "Cancelled" }
            } catch {
                if token == generation { message = error.localizedDescription }
            }
            if token == generation { busy = false; stopping = false; task = nil }
        }
    }
    private func progress(_ completed: Int, total: Int, generation: UUID) {
        guard generation == self.generation else { return }
        self.completed = completed; self.total = total
    }
    func cancel() { stopping = true; task?.cancel() }
    func close() {
        generation = UUID(); task?.cancel(); task = nil; clearBatch()
    }
    func save() {
        guard !busy && !saving, let batch, !batch.outputs.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Save converted documents"; panel.prompt = "Save Here"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        saving = true
        let previous = Set(saved.keys)
        Task {
            let report = await Task.detached { DocumentConverter.save(batch, to: directory, excluding: previous) }.value
            saved.merge(report.saved) { _, new in new }
            message = "\(saved.count) PDFs saved." + (report.errors.isEmpty ? "" : "\n" + report.errors.joined(separator: "\n"))
            saving = false
        }
    }
}

struct ConvertWorkspace: View {
    @StateObject private var model: ConversionModel
    @MainActor init() { _model = StateObject(wrappedValue: ConversionModel()) }
    init(model: ConversionModel) { _model = StateObject(wrappedValue: model) }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if model.inputs.isEmpty { emptyState }
                else {
                    ReaderSplit(sizing: .sidebar, minimum: ReaderSidebar.minimum, maximum: ReaderSidebar.maximum, minimumContent: 400, label: "conversion files", pane: {
                        fileQueue.frame(maxHeight: .infinity).background(RemileStyle.sidebar)
                    }, content: { preview.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity) })
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }.frame(width: 940, height: 600)
            .background(RemileStyle.background).modifier(ReaderAppearanceModifier())
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.busy && !model.saving else { return false }
                model.add(urls); return !urls.isEmpty
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.inputs.isEmpty)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.busy)
            .interactiveDismissDisabled(model.busy || model.saving)
            .onDisappear { model.close() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            DocumentToolHeader(title: "Convert to PDF", subtitle: "Images, Word and Markdown", symbol: "doc.badge.arrow.up")
            if !model.inputs.isEmpty {
                Button { model.choose() } label: { Label("Add Files…", systemImage: "plus") }
                    .disabled(model.busy || model.saving)
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var emptyState: some View {
        DocumentToolEmptyState(symbols: ["photo", "doc.text", "text.document"], title: "Make a PDF from your files", detail: "Drop files here, or choose them below.\nReview each result before saving.", button: "Choose Files…", formats: "JPG, PNG, HEIC · DOC, DOCX · MD", choose: model.choose)
    }

    private var fileQueue: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FILES · \(model.inputs.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(16)
            ScrollView {
                LazyVStack(spacing: 4) {
                    if let batch = model.batch {
                        ForEach(batch.items) { item in
                            Button { model.selected = item.id } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: model.saved[item.id] != nil ? "checkmark.circle.fill" : item.output == nil ? "exclamationmark.triangle" : "doc.text")
                                        .foregroundStyle(item.output == nil ? Color.orange : RemileStyle.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.input.lastPathComponent).font(.callout.weight(.medium)).lineLimit(2)
                                        Text(model.saved[item.id] != nil ? "Saved" : item.output != nil ? "Ready to save" : "Could not convert").font(RemileType.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selected == item.id ? RemileStyle.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    } else {
                        ForEach(model.inputs, id: \.self) { url in
                            HStack(spacing: 10) {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                Text(url.lastPathComponent).font(RemileType.callout).lineLimit(2)
                                Spacer(minLength: 0)
                                Button { model.remove(url) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).remileHelp("Remove \(url.lastPathComponent)").disabled(model.busy || model.saving)
                            }.padding(12)
                        }
                    }
                }.padding(.horizontal, 8)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let item = model.selectedItem {
                HStack {
                    Text("PDF Preview").font(RemileType.heading)
                    Spacer()
                    if item.output != nil { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                }
                if let message = item.message { Text(message).font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let output = item.output { ConversionPreview(url: output).id(output).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ContentUnavailableView("This file needs attention", systemImage: "exclamationmark.triangle").frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(model.busy ? "Preparing your PDFs…" : "\(model.inputs.count) files ready to convert").font(.title3.weight(.medium))
                    Text(model.busy ? "Your preview will appear here." : "Convert your files, then check each page here.")
                        .font(RemileType.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.stopping ? "Stopping…" : model.activeFile).font(RemileType.caption).lineLimit(1)
                    Spacer()
                    Text("\(model.completed) / \(model.total)").font(RemileType.caption).monospacedDigit()
                }
                ProgressView(value: model.fraction ?? 0)
            }
            if let message = model.message { Text(message).font(RemileType.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                Button("Close") { dismiss() }.disabled(model.busy || model.saving).keyboardShortcut(.cancelAction)
                if model.saving { ProgressView("Saving…").controlSize(.small) }
                else { Text("Original files stay unchanged").font(RemileType.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.busy { Button("Stop", action: model.cancel).disabled(model.stopping) }
                else if let batch = model.batch, !batch.outputs.isEmpty {
                    Button("Convert Again", action: model.convert).disabled(model.saving)
                    Button("Save PDFs…", action: model.save).buttonStyle(.borderedProminent)
                        .disabled(model.saving || model.saved.count == batch.outputs.count).keyboardShortcut(.defaultAction)
                } else if !model.inputs.isEmpty {
                    Button("Convert to PDF", action: model.convert).buttonStyle(.borderedProminent)
                        .disabled(model.saving).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(RemileStyle.surface)
    }
}

private actor PreviewRenderer {
    func render(_ url: URL, page: Int) -> (NSImage?, Int) {
        autoreleasepool {
            guard let document = PDFDocument(url: url) else { return (nil, 0) }
            return (document.page(at: page)?.thumbnail(of: NSSize(width: 1224, height: 1584), for: .mediaBox), document.pageCount)
        }
    }
}

@MainActor
private final class ConversionPage: ObservableObject {
    @Published private(set) var page = 0
    @Published private(set) var image: NSImage?
    @Published private(set) var count = 0
    @Published private(set) var loading = true
    private let url: URL
    private let renderer = PreviewRenderer()
    private var task: Task<Void, Never>?
    init(url: URL) { self.url = url }
    func show(_ number: Int) {
        guard number >= 0, count == 0 || number < count else { return }
        task?.cancel(); page = number; loading = true
        let url = url
        task = Task {
            let result = await renderer.render(url, page: number)
            guard !Task.isCancelled else { return }
            image = result.0; count = result.1; loading = false
        }
    }
    func stop() { task?.cancel() }
}

struct ConversionPreview: View {
    @StateObject private var model: ConversionPage
    let initialPage: Int
    let pageChanged: (Int) -> Void
    init(url: URL, initialPage: Int = 0, pageChanged: @escaping (Int) -> Void = { _ in }) {
        self.initialPage = initialPage; self.pageChanged = pageChanged
        _model = StateObject(wrappedValue: ConversionPage(url: url))
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { model.show(model.page - 1); pageChanged(model.page) } label: { Image(systemName: "chevron.left") }.disabled(model.loading || model.page == 0).remileHelp("Previous preview page")
                Spacer()
                Text(model.count == 0 ? "Loading…" : "Page \(model.page + 1) of \(model.count)").font(RemileType.caption).monospacedDigit()
                Spacer()
                Button { model.show(model.page + 1); pageChanged(model.page) } label: { Image(systemName: "chevron.right") }.disabled(model.loading || model.page + 1 >= model.count).remileHelp("Next preview page")
            }
            if model.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let image = model.image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Converted page \(model.page + 1)")
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle")
            }
        }.task { model.show(initialPage) }.onDisappear { model.stop() }
    }
}
