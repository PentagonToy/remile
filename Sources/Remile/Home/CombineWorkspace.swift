import SwiftUI
import UniformTypeIdentifiers

@MainActor final class CombinationModel: ObservableObject {
    @Published var inputs: [URL]
    @Published var busy = false
    @Published var error: String?
    init(inputs: [URL] = []) { self.inputs = inputs }
    var kind: DocumentTools.Kind? { try? DocumentTools.kind(inputs) }
    func add(_ urls: [URL]) {
        let candidate = inputs + urls.filter { !inputs.contains($0) }
        do { _ = try DocumentTools.kind(candidate); inputs = candidate; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func choose() {
        let panel = NSOpenPanel(); panel.title = "Choose files to combine"; panel.allowedContentTypes = [.pdf, .remileMarkdown]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }; add(panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }
    func save(open: @escaping (URL) -> Void, close: @escaping () -> Void) {
        guard inputs.count >= 2, let kind, !busy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = kind == .pdf ? [.pdf] : [.remileMarkdown]
        panel.nameFieldStringValue = "combined_" + (inputs.first?.deletingPathExtension().lastPathComponent ?? "Document") + (kind == .pdf ? ".pdf" : ".md")
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let inputs = inputs; busy = true; error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try DocumentTools.create(.combine, inputs: inputs, destination: output) }.value
                busy = false; close(); open(output)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}

struct CombineWorkspace: View {
    @ObservedObject var model: CombinationModel
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DocumentToolHeader(title: "Combine files", subtitle: "PDFs or Markdown, in your order", symbol: "square.stack")
                if !model.inputs.isEmpty { Button { model.choose() } label: { SymbolLabel("Add Files…", systemImage: "plus") }.disabled(model.busy) }
            }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            Group {
                if model.inputs.isEmpty {
                    DocumentToolEmptyState(symbols: ["doc", "square.stack", "doc.text"], title: "Bring your pages together", detail: "Drop files here, or choose them below.\nUse PDFs together, or Markdown files together.", button: "Choose Files…", formats: "PDF · MD", choose: model.choose)
                } else { fileQueue.padding(24) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }.frame(width: 940, height: 600).background(RemileStyle.background).modifier(ReaderAppearanceModifier())
            .interactiveDismissDisabled(model.busy)
            .dropDestination(for: URL.self) { urls, _ in guard !model.busy, !urls.isEmpty else { return false }; model.add(urls); return true }
    }

    private var fileQueue: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("FILES · \(model.inputs.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Arrange files before saving.").font(RemileType.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(model.inputs.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 14) {
                            Text("\(index + 1)").font(RemileType.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                            SymbolIcon(systemName: model.kind == .markdown ? "doc.text" : "doc.richtext").foregroundStyle(RemileStyle.accent).frame(width: 28)
                            Text(url.lastPathComponent).font(RemileType.callout).lineLimit(1).truncationMode(.middle).help(url.lastPathComponent)
                            Spacer(minLength: 12)
                            Button { model.inputs.swapAt(index, index - 1) } label: { SymbolIcon(systemName: "chevron.up") }.disabled(index == 0).remileHelp("Move up")
                            Button { model.inputs.swapAt(index, index + 1) } label: { SymbolIcon(systemName: "chevron.down") }.disabled(index == model.inputs.count - 1).remileHelp("Move down")
                            Button { model.inputs.remove(at: index) } label: { SymbolIcon(systemName: "xmark") }.buttonStyle(.borderless).remileHelp("Remove file")
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.scrollContentGutter()
            }.disabled(model.busy)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.error { Text(error).font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Text("Original files stay unchanged").font(RemileType.caption).foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView("Combining…").controlSize(.small) }
                else if !model.inputs.isEmpty {
                    if model.inputs.count < 2 { Text("Add one more file to combine.").font(RemileType.caption).foregroundStyle(.secondary) }
                    Button(model.kind == .markdown ? "Save Markdown…" : "Save PDF…") { model.save(open: open, close: { dismiss() }) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.inputs.count < 2 || model.kind == nil)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(RemileStyle.surface)
    }
}
