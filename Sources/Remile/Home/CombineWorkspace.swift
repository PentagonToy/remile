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
        panel.nameFieldStringValue = kind == .pdf ? "Combined.pdf" : "Combined.md"
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
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Combine").font(RemileType.heading); Spacer(); Button("Add files…", action: model.choose).disabled(model.busy) }
            if model.inputs.isEmpty { ContentUnavailableView("Choose PDF or Markdown files", systemImage: "square.stack").frame(height: 220) }
            else { ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(model.inputs.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 10) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle); Spacer()
                            Button { model.inputs.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("Move up")
                            Button { model.inputs.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index == model.inputs.count - 1).help("Move down")
                            Button { model.inputs.remove(at: index) } label: { Image(systemName: "minus.circle") }.help("Remove file")
                        }.padding(8)
                    }
                }
            }.frame(height: 220).disabled(model.busy) }
            if let error = model.error { Text(error).font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.kind == .markdown ? "Save Markdown…" : "Save PDF…") { model.save(open: open, close: { dismiss() }) }.keyboardShortcut(.defaultAction).disabled(model.inputs.count < 2 || model.kind == nil || model.busy)
            }
        }.padding(22).frame(width: 580).background(RemileStyle.background).interactiveDismissDisabled(model.busy)
            .dropDestination(for: URL.self) { urls, _ in guard !model.busy else { return false }; model.add(urls); return true }
    }
}
