import SwiftUI
import UniformTypeIdentifiers

struct PDFCommentExportMenu: View {
    @ObservedObject var session: PDFSession
    let name: String
    @StateObject private var state = State()
    private final class State: ObservableObject { @Published var error: String? }
    var body: some View {
        Menu {
            Button("Markdown…") { save(.markdown) }
            Button("JSON…") { save(.json) }
        } label: { SymbolIcon(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).tint(RemileStyle.ink).fixedSize().remileHelp("Export comments").accessibilityLabel("Export comments")
            .disabled(session.document?.isLocked != false)
            .alert("Unable to export comments", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) { Button("OK") { state.error = nil } } message: { Text(state.error ?? "") }
    }
    private func save(_ format: PDFCommentExport.Format) {
        let panel = NSSavePanel(); panel.allowedContentTypes = format == .json ? [.json] : [.remileMarkdown]
        panel.nameFieldStringValue = (name as NSString).deletingPathExtension + " comments." + (format == .json ? "json" : "md")
        guard panel.runModal() == .OK, let output = panel.url else { return }
        do { try PDFCommentExport.data(session.exportComments(name: name), format: format).write(to: output, options: .atomic) }
        catch { state.error = error.localizedDescription }
    }
}
