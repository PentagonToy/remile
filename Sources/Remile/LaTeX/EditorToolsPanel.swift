import SwiftUI

struct EditorToolsPanel: View {
    @ObservedObject var project: TeXProject
    @Environment(\.dismiss) private var dismiss
    @AppStorage("editor.focusMode") private var focus = false
    @State private var selection: Tool?
    @State private var proposal: Proposal?
    @State private var pendingBibliography: BibliographyRequest?
    @State private var message: String?

    init(project: TeXProject, tool: Tool = .focus) {
        self.project = project
        _selection = State(initialValue: tool)
    }

    private var bibliographyTool: Tool {
        TeXSourceTools.hasEmbeddedBibliography(project.buffers[project.main] ?? "") ? .restore : .bibliography
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Writing tools").font(RemileType.heading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if let proposal { review(proposal) }
            else { tools }
            Divider()
            footer
        }
        .frame(width: 560, height: 392)
        .foregroundStyle(RemileStyle.ink)
        .background(RemileStyle.background)
        .onChange(of: selection) { _, _ in message = nil }
        .onChange(of: bibliographyTool) { previous, current in
            if selection == previous { selection = current }
        }
        .onChange(of: project.compiling) { _, compiling in
            if !compiling { finishBibliography() }
        }
    }

    private var tools: some View {
        HStack(spacing: 0) {
            List([Tool.focus, .notes, bibliographyTool], selection: $selection) { tool in
                SymbolLabel(tool.label, systemImage: tool.symbol)
                    .labelStyle(SymbolLabelStyle())
                    .font(RemileType.control)
                    .frame(maxWidth: .infinity, minHeight: RemileControl.toolHit, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(tool)
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .tint(RemileStyle.accent).accessibilityLabel("Writing tools")
            .padding(.vertical, 8).padding(.horizontal, 4)
            .frame(width: 200).background(RemileStyle.sidebar)
            .disabled(pendingBibliography != nil)
            Divider()
            if let selection {
                Example(tool: selection)
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("Choose a tool").foregroundStyle(RemileStyle.secondaryInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func review(_ proposal: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(proposal.title).font(.headline)
            Text(proposal.file).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                .truncationMode(.middle).lineLimit(1).help(proposal.file)
            HStack(spacing: 12) {
                sourcePreview("Before", proposal.before)
                sourcePreview("After", proposal.after)
            }
            Text(proposal.bibliography == nil
                 ? "Undo restores the edit. Save writes your project."
                 : "Run Submission check before saving.")
                .font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sourcePreview(_ title: String, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(RemileType.caption.weight(.semibold))
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: String(source.prefix(150_000)))
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if pendingBibliography != nil {
                ProgressView().controlSize(.small)
                Text("Compiling bibliography…").font(RemileType.caption)
            } else if let message {
                Text(message).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                .buttonStyle(RemileActionStyle())
            if let proposal {
                Button("Apply to editor") { apply(proposal) }
                    .buttonStyle(RemileActionStyle(emphasis: .primary)).keyboardShortcut(.defaultAction)
            } else if let selection {
                Button(selection == .focus ? (focus ? "Turn off" : "Turn on") : "Review changes") {
                    switch selection {
                    case .focus: focus.toggle(); dismiss()
                    case .notes: prepareNotes()
                    case .bibliography: prepareBibliography()
                    case .restore: prepareRestore()
                    }
                }
                .buttonStyle(RemileActionStyle(emphasis: .primary)).keyboardShortcut(.defaultAction)
                .disabled(selection != .focus && (project.compiling || pendingBibliography != nil))
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func prepareNotes() {
        let file = project.selected
        guard let before = project.buffers[file] else { message = "Select a source file."; return }
        do {
            let edit = try TeXTools.prepare("strip-notes", project: project, file: file)
            guard edit.count > 0 else { message = "No author notes in this file."; return }
            let title = edit.count == 1 ? "Remove 1 author note" : "Remove \(edit.count) author notes"
            proposal = Proposal(file: file, before: before, after: edit.source, title: title, root: project.root)
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func prepareBibliography() {
        let request = BibliographyRequest(root: project.root, main: project.main, buffers: project.buffers)
        pendingBibliography = request
        message = nil
        if project.build?.buffers != request.buffers || project.build?.main != request.main || project.compileFailed {
            project.compile()
        }
        if !project.compiling { finishBibliography() }
    }

    private func prepareRestore() {
        let file = project.main
        guard let before = project.buffers[file] else { return }
        do {
            let edit = try TeXTools.prepare("restore-bibliography", project: project, file: file)
            proposal = Proposal(file: file, before: before, after: edit.source, title: edit.title,
                                root: project.root, references: edit.references)
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func finishBibliography() {
        guard let request = pendingBibliography else { return }
        pendingBibliography = nil
        guard request.matches(project) else { message = "The source changed. Review it again."; return }
        guard !project.compileFailed, let before = request.buffers[request.main] else {
            message = "Compile the current project successfully first."
            return
        }
        do {
            let edit = try TeXTools.prepare("embed-bibliography", project: project, file: request.main)
            proposal = Proposal(file: request.main, before: before, after: edit.source, title: edit.title,
                                root: request.root, bibliography: request)
        } catch { message = error.localizedDescription }
    }

    private func apply(_ proposal: Proposal) {
        guard project.root == proposal.root, project.buffers[proposal.file] == proposal.before, !project.compiling,
              (proposal.references.isEmpty || proposal.file == project.main),
              proposal.bibliography?.matches(project) != false else {
            self.proposal = nil
            message = "The source changed. Review it again."
            return
        }
        do { try TeXTools.requireReferences(proposal.references, in: project) }
        catch { message = error.localizedDescription; return }
        if project.applyTool(file: proposal.file, before: proposal.before, after: proposal.after, name: proposal.title) {
            dismiss()
        } else { message = project.message }
    }
}

extension EditorToolsPanel {
    enum Tool: String, Identifiable {
        case focus = "Focus paragraph"
        case notes = "Remove author notes"
        case bibliography = "Embed references"
        case restore = "Restore references"

        var id: Self { self }
        var label: String {
            switch self {
            case .notes: "Remove notes"
            default: rawValue
            }
        }
        var symbol: String {
            switch self {
            case .focus: "text.alignleft"
            case .notes: "text.bubble"
            case .bibliography, .restore: "books.vertical"
            }
        }
        var detail: String {
            switch self {
            case .focus: "Dim the text around the paragraph you are editing."
            case .notes: "Remove % notes from the current file. Keep TeX directives."
            case .bibliography: "Put compiled BibTeX references into the main source."
            case .restore: "Reconnect the original .bib files."
            }
        }
    }

    private struct Proposal {
        let file: String
        let before: String
        let after: String
        let title: String
        let root: URL
        var bibliography: BibliographyRequest?
        var references: [String] = []
    }

    private struct BibliographyRequest {
        let root: URL
        let main: String
        let buffers: [String: String]

        @MainActor func matches(_ project: TeXProject) -> Bool {
            root == project.root && main == project.main && buffers == project.buffers
        }
    }

    struct Example: View {
        let tool: Tool

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(tool.rawValue).font(.headline)
                Text(tool.detail).font(RemileType.control).foregroundStyle(RemileStyle.secondaryInk)
                Text("Example").font(RemileType.caption.weight(.semibold)).foregroundStyle(RemileStyle.secondaryInk)
                    .padding(.top, 6)
                switch tool {
                case .focus:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("We measured the inlet velocity.").foregroundStyle(RemileStyle.secondaryInk)
                        Text("The model resolves the flame front.").fontWeight(.semibold)
                        Text("The next section compares the results.").foregroundStyle(RemileStyle.secondaryInk)
                    }.font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                case .notes:
                    sample("Before", "% Check caption units.\n" + #"\caption{Flame speed}"#)
                    sample("After", #"\caption{Flame speed}"#)
                case .bibliography:
                    sample("Before", #"\bibliography{references}"#)
                    sample("After", Self.inlineExample)
                case .restore:
                    sample("Before", Self.inlineExample)
                    sample("After", #"\bibliography{references}"#)
                }
            }
        }

        private static let inlineExample = #"""
        \begin{thebibliography}{1}
        \bibitem{lee} Lee, 2024.
        \end{thebibliography}
        """#

        private func sample(_ title: String, _ text: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                Text(verbatim: text).font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
        }
    }
}
