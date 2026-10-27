import SwiftUI
import UniformTypeIdentifiers

struct ManuscriptReviewPanel: View {
    @ObservedObject var project: TeXProject
    @ObservedObject private var store: ManuscriptReviewStore
    @StateObject private var state = State()
    private final class State: ObservableObject { @Published var error: String?; @Published var hashes: [String: String] = [:] }
    init(project: TeXProject, store: ManuscriptReviewStore? = nil) { self.project = project; self.store = store ?? project.review }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Manuscript review").font(RemileType.callout.weight(.semibold)); Spacer()
                AIProviderButton()
            }
            ViewThatFits(in: .horizontal) {
                actions(compact: false)
                actions(compact: true)
            }
            Text("Questions to consider.").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            if let message = state.error ?? store.message { Text(message).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk).textSelection(.enabled) }
            Divider()
            if store.archive.runs.isEmpty && !store.running {
                Text("Review the current file. Saved questions stay until you clear them.")
                    .font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(store.archive.runs.reversed()) { run in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(run.scope).font(RemileType.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(run.createdAt.formatted(date: .abbreviated, time: .shortened)).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                            if run.sourceHashes.contains(where: { state.hashes[$0.key] != $0.value }) { SymbolLabel("Source changed · check context", systemImage: "clock.arrow.circlepath").font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
                            if run.questions.isEmpty { Text("No questions returned for this scope.").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk) }
                            ForEach(run.questions) { item in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(item.question).font(RemileType.callout.weight(.semibold)).textSelection(.enabled)
                                    Text(item.reason).font(RemileType.caption).textSelection(.enabled)
                                    ForEach(Array(item.anchors.enumerated()), id: \.offset) { _, anchor in
                                        Button { reveal(anchor) } label: { VStack(alignment: .leading, spacing: 4) { SymbolLabel(anchor.file + ":" + String(anchor.line + 1), systemImage: "doc.text.magnifyingglass").lineLimit(2); Text(anchor.quote).lineLimit(4).foregroundStyle(RemileStyle.secondaryInk) } }.buttonStyle(.plain).font(RemileType.caption).remileHelp("Locate the quoted passage in the current source")
                                    }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }
                }.scrollContentGutter()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(12).background(RemileStyle.background)
            .task(id: String(project.editRevision) + ":" + String(project.fileRevision)) { state.hashes = project.sourceHashes }
    }
    private func actions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if store.running { ProgressView().controlSize(.small); Button("Stop") { store.stop() } }
            else { Button(compact ? "Review" : "Review file") { do { state.error = nil; try store.start(buffers: project.buffers, selected: project.selected) } catch { state.error = error.localizedDescription } }.disabled(project.buffers[project.selected] == nil) }
            Spacer(minLength: 0)
            Menu { Button("Markdown…") { export(json: false) }; Button("JSON…") { export(json: true) } } label: { SymbolIcon(systemName: "square.and.arrow.up") }.menuIndicator(.hidden).accessibilityLabel("Export review questions").disabled(store.archive.runs.isEmpty)
            Button("Clear") { do { try store.clear(); state.error = nil } catch { state.error = error.localizedDescription } }.disabled(!store.hasSavedData && !store.running)
        }.font(RemileType.caption)
    }
    private func reveal(_ anchor: ReviewAnchor) {
        guard let source = project.buffers[anchor.file] else { state.error = "The source file is no longer available. The saved question is kept."; return }
        if SourceDigest.sha256(source) == anchor.sourceSHA256 { project.visit(file: anchor.file, line: anchor.line); return }
        guard source.components(separatedBy: anchor.quote).count == 2, let range = source.range(of: anchor.quote) else { state.error = "The passage has changed or is ambiguous. The saved question is kept."; return }
        project.visit(file: anchor.file, line: source[..<range.lowerBound].filter { $0 == "\n" }.count)
    }
    private func export(json: Bool) {
        let panel = NSSavePanel(); panel.allowedContentTypes = json ? [.json] : [.remileMarkdown]
        panel.nameFieldStringValue = project.displayName.replacingOccurrences(of: "/", with: "-") + " review." + (json ? "json" : "md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let bytes = json ? try ReviewArchive.encoder().encode(store.archive) : Data(store.archive.markdown().utf8); try bytes.write(to: url, options: .atomic) }
        catch { state.error = error.localizedDescription }
    }
}
