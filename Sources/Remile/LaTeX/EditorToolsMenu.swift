import SwiftUI

/// Reviewable source actions share the native editor's Undo and explicit Save path.
struct EditorToolsMenu: View {
    @ObservedObject var project: TeXProject
    let editor: MarkdownEditorController
    @StateObject private var state = State()
    @AppStorage("editor.focusMode") private var focus = false
    private final class State: ObservableObject {
        @Published var proposal: Proposal?
        @Published var preparing = false
        @Published var error: String?
        var task: Task<Void, Never>?
    }
    private struct Proposal: Identifiable {
        let id = UUID()
        let file: String
        let before: String
        let after: String
        let title: String
        let warning: String
    }
    var body: some View {
        Menu {
            Toggle("Focus paragraph", isOn: $focus)
            Divider()
            Button("Remove notes (%)…") { notes() }
            Button(state.preparing ? "Embedding bibliography…" : "Embed bibliography…") { bibliography() }.disabled(project.compiling || state.preparing)
        } label: { Image(systemName: "wand.and.stars") }.remileHelp("Writing and submission tools")
            .sheet(item: $state.proposal) { proposal in
                VStack(alignment: .leading, spacing: 16) {
                    Text(proposal.title).font(.title2.weight(.semibold))
                    Text(proposal.file).font(.callout).foregroundStyle(.secondary)
                    Text(proposal.warning).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        sourcePreview("Before", proposal.before)
                        sourcePreview("After", proposal.after)
                    }
                    HStack {
                        Text("Undo restores the edit. Save writes your project.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { state.proposal = nil }.keyboardShortcut(.cancelAction)
                        Button("Apply to editor") { apply(proposal) }.keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 800, height: 550)
            }
            .alert("Source action unavailable", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) { Button("OK") { state.error = nil } } message: { Text(state.error ?? "") }
            .onDisappear { state.task?.cancel() }
    }
    private func sourcePreview(_ title: String, _ source: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView([.horizontal, .vertical]) { Text(String(source.prefix(150_000))).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12) }.background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
        }.frame(maxWidth: .infinity)
    }
    private func notes() {
        let before = project.buffers[project.selected] ?? ""
        do {
            let edit = try TeXTools.prepare("strip-notes", project: project, file: project.selected)
            guard edit.count > 0 else { state.error = "No removable author notes in this file."; return }
            state.proposal = Proposal(file: project.selected, before: before, after: edit.source, title: "Remove \(edit.count) author notes?", warning: "Removes % notes. Figure/table captions and TeX directives stay. Undo restores the edit.")
        } catch { state.error = error.localizedDescription }
    }
    private func bibliography() {
        let main = project.main, buffers = project.buffers, root = project.root
        state.preparing = true
        state.task = Task { @MainActor in
            defer { state.preparing = false }
            if project.build?.buffers != buffers || project.build?.main != main { project.compile() }
            while project.compiling { do { try await Task.sleep(for: .milliseconds(200)) } catch { return } }
            guard !Task.isCancelled else { return }
            do {
                guard project.root == root, project.buffers == buffers, let build = project.build, build.buffers == buffers, build.main == main, let before = buffers[main] else { throw TeXSourceTools.Failure(errorDescription: "Compile this unchanged project successfully before embedding its bibliography.") }
                let after = try TeXTools.prepare("embed-bibliography", project: project, file: main).source
                state.proposal = Proposal(file: main, before: before, after: after, title: "Embed bibliography", warning: "Moves the compiled references into the main source. Undo restores the edit. Run Submission check before saving.")
            } catch { state.error = error.localizedDescription }
        }
    }
    private func apply(_ proposal: Proposal) {
        guard project.buffers[proposal.file] == proposal.before, !project.compiling else { state.proposal = nil; state.error = "The source changed. Prepare this action again."; return }
        guard project.applyTool(file: proposal.file, before: proposal.before, after: proposal.after, name: proposal.title) else { state.error = project.message; return }
        state.proposal = nil
    }
}
