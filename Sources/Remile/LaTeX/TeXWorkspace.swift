import SwiftUI
import PDFKit

struct TeXWorkspace: View {
    @ObservedObject var project: TeXProject
    let close: () -> Void
    var title = "LaTeX"
    @StateObject private var editor = MarkdownEditorController()
    @StateObject private var writing = EditorWritingReview()
    @StateObject private var zoom = ReaderZoom()
    @StateObject private var preview = TeXPDFController()
    @StateObject private var presentation = Presentation()
    private final class Presentation: ObservableObject { @Published var notice = false; @Published var renameProject = false; @Published var renameSource = false; @Published var files = false; @Published var pane = "Source" }
    @AppStorage("latex.fontSize") private var fontSize = 17
    @AppStorage("editor.language") private var language = "Automatic"
    @AppStorage("editor.spellcheck") private var spellcheck = true
    @AppStorage("editor.showExternalEdits") private var showExternalEdits = false
    @AppStorage("latex.theme") private var theme = TeXEditorTheme.remile.rawValue
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                if geometry.size.width < 820 {
                    VStack(spacing: 0) {
                        HStack {
                            Button { presentation.files.toggle() } label: { Label("Files", systemImage: "sidebar.left") }.remileHelp("Files and outline")
                                .popover(isPresented: $presentation.files) { TeXProjectSidebar(project: project).frame(width: 250, height: 460) }
                            Spacer()
                            Picker("Pane", selection: $presentation.pane) { Text("Source").tag("Source"); Text("Preview").tag("Preview") }.labelsHidden().pickerStyle(.segmented).frame(width: 190)
                        }.padding(8)
                        if presentation.pane == "Source" { sourcePane } else { previewPane }
                    }
                } else {
                    ReaderSplit(initial: 220, minimum: 160, maximum: 340, minimumContent: 580, label: "project files", revealToken: navigationToken, pane: { TeXProjectSidebar(project: project) }, content: {
                        ReaderSplit(initial: 440, minimum: 260, maximum: 1400, minimumContent: 280, label: "LaTeX source", revealToken: navigationToken, pane: { sourcePane }, content: { previewPane })
                    })
                }
            }
            ReaderThemeFooter()
        }.background(RemileStyle.background).navigationTitle(project.displayName + (project.dirty ? " •" : ""))
        .task(id: project.selected + project.source.wrappedValue + language + String(spellcheck)) { await writing.check(project.source.wrappedValue, enabled: spellcheck, language: language, editor: editor) }
        .onAppear {
            editor.syncToPreview = { project.syncToPDF(line: $0) }; preview.reverse = { project.syncToSource($0) }
            editor.synonymsRequested = { [weak writing = writing, weak editor = editor] range, view in guard let editor else { return }; _ = writing?.showSuggestion(at: range, in: view, editor: editor, synonymsOnly: true) }
            editor.proofreadRequested = { [weak writing = writing, weak editor = editor] range, view in guard let editor else { return }; writing?.proofread(range, in: view, editor: editor) }
            editor.writingIssueRequested = { [weak writing = writing, weak editor = editor] range, view in guard let editor else { return false }; return writing?.showSuggestion(at: range, in: view, editor: editor) ?? false }
            editor.dismissWriting = { [weak writing = writing] in writing?.dismissSuggestion() }
            project.editSource = { [weak editor = editor, weak project = project] file, before, after, name in
                guard let editor, let project, let view = editor.textView, !view.hasMarkedText() else { return false }
                project.selected = file; presentation.pane = "Source"
                editor.update(before, size: CGFloat(fontSize), serif: false, document: file)
                editor.apply(.init(range: NSRange(location: 0, length: (before as NSString).length), text: after, selection: NSRange(location: 0, length: 0)), name: name)
                return true
            }
            if !TeXConfiguration.current.missingTools(buffers: project.buffers).isEmpty { project.setupNeeded = true }
        }
        .onDisappear { project.editSource = nil; writing.dismissSuggestion() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("remile.toggleComment"))) { event in if event.object as? TeXProject === project { editor.toggleComment() } }
        .onReceive(project.$sourceJump) { jump in
            guard let jump else { return }; presentation.pane = "Source"
            editor.update(project.buffers[jump.location.file] ?? "", size: CGFloat(fontSize), serif: false, document: jump.location.file)
            editor.reveal(line: jump.location.line); editor.flash(line: jump.location.line)
        }
    }
    private var sourcePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                InlineName(value: (project.selected as NSString).lastPathComponent, editing: $presentation.renameSource) { project.rename(project.selected, to: $0) }.font(RemileType.caption).frame(maxWidth: .infinity, alignment: .leading)
                if project.dirty { Text("•").foregroundStyle(.secondary) }
                Button { editor.textView?.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }.remileHelp("Undo the last source edit (⌘Z)").disabled(editor.textView?.undoManager?.canUndo != true)
                Button { editor.textView?.undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }.remileHelp("Restore the last undone edit (⇧⌘Z)").disabled(editor.textView?.undoManager?.canRedo != true)
                Menu { ForEach([12, 14, 16, 17, 18, 20, 24, 28], id: \.self) { value in Button("\(value) pt") { fontSize = value } } } label: { Text("\(fontSize)").monospacedDigit().font(RemileType.small) }.remileHelp("Text size")
                Button { project.syncToPDF(line: editor.selectedLine); presentation.pane = "Preview" } label: { Image(systemName: "arrow.right") }.disabled(!project.canSync).remileHelp("Show in PDF")
            }.buttonStyle(RemileToolStyle()).padding(.horizontal, 10).background(RemileStyle.editorBar)
            MarkdownEditor(source: project.source, controller: editor, size: CGFloat(fontSize), serif: false, texTheme: TeXEditorTheme(rawValue: theme) ?? .remile, documentID: project.selected, externalRanges: project.externalEdits[project.selected] ?? [], showExternalEdits: showExternalEdits)
        }
    }
    private var previewPane: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button { if let location = preview.currentLocation() { project.syncToSource(location) }; presentation.pane = "Source" } label: { Image(systemName: "arrow.left") }.disabled(!project.canSync).remileHelp("Show in source")
                    Spacer(minLength: 0)
                    ReaderPageControl(current: preview.page, total: preview.pages, go: preview.go)
                    ReaderZoomControls(zoom: zoom)
                }.buttonStyle(RemileToolStyle()).padding(.horizontal, 8).background(RemileStyle.editorBar)
                if let pdf = project.pdf { TeXPDFPreview(document: pdf, zoom: zoom, controller: preview, jump: project.pdfJump) }
                else { ContentUnavailableView("Compile to preview", systemImage: "doc.richtext").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.opacity(project.showsLog || project.showsHistory ? 0 : 1).allowsHitTesting(!project.showsLog && !project.showsHistory).accessibilityHidden(project.showsLog || project.showsHistory)
            if project.showsHistory { TeXHistoryPanel(project: project) }
            else if project.showsLog { TeXLogPanel(project: project) }
        }
    }
    private var navigationToken: String { project.selected + (project.sourceJump?.id.uuidString ?? "") + (project.pdfJump?.id.uuidString ?? "") + String(project.showsLog) + String(project.showsHistory) }
    private func noticeTitle(_ message: String) -> String {
        switch message {
        case "Check TeX references after moving or renaming a file.": return "Check TeX references"
        case "Recompile to match source and PDF.": return "Recompile to navigate"
        case "Compile to enable source/PDF navigation.": return "Compile to navigate"
        case "Choose another main document before removing this item.": return "Choose another main document"
        case "The source changed. Prepare this action again.": return "Source changed · try again"
        default: return message.hasPrefix("Save failed:") ? "Save failed" : message.count <= 32 ? message : "Project notice"
        }
    }
    private var toolbar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Button(action: close) { Image(systemName: "chevron.left") }.remileHelp("Home")
                Text(title).font(RemileType.callout.weight(.semibold)).lineLimit(1).fixedSize()
                InlineName(value: project.displayName, editing: $presentation.renameProject) { project.renameProject(to: $0) }.font(RemileType.callout).frame(maxWidth: .infinity, alignment: .leading).disabled(project.connected)
                if let message = project.message {
                    Button { presentation.notice.toggle() } label: { Text(noticeTitle(message)).font(RemileType.caption).fixedSize(horizontal: true, vertical: false) }
                        .buttonStyle(.plain).remileHelp(message)
                        .popover(isPresented: $presentation.notice) { Text(message).font(RemileType.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(16).frame(width: 300, alignment: .leading).background(RemileStyle.background) }
                }

            }
            HStack(alignment: .center, spacing: 8) {
                Button { project.goBack() } label: { Image(systemName: "arrow.backward") }.disabled(project.backFiles.isEmpty).remileHelp("Return to the previous source location")
                Button { project.goForward() } label: { Image(systemName: "arrow.forward") }.disabled(project.forwardFiles.isEmpty).remileHelp("Go to the next source location")
                AIProviderButton()
                EditorToolsMenu(project: project, editor: editor)
                Button { showExternalEdits.toggle() } label: { Image(systemName: showExternalEdits ? "eye" : "eye.slash") }.remileHelp(RemileHints.edits(showExternalEdits)).accessibilityLabel("Show AI and CLI edits")
                Button { project.captureHistory(file: project.selected); project.showsHistory.toggle(); project.showsLog = false; presentation.pane = "Preview" } label: { Image(systemName: "clock.arrow.circlepath") }.remileHelp(RemileHints.history(project.showsHistory))
                Button { project.showsHistory = false; project.showsLog.toggle(); presentation.pane = "Preview" } label: { Image(systemName: project.showsLog ? "doc.richtext" : "terminal") }.remileHelp(RemileHints.logs(project.showsLog))
                Spacer(minLength: 0)
                Menu { Button("PDF…") { project.export() }.disabled(project.pdf == nil); Button("Source (.zip)…") { project.exportSource() } } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold)).frame(width: 22, height: 22).offset(y: -3.5) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32, height: 32).remileHelp("Export")
                if !project.compiling, project.diagnostics.contains(where: { $0.severity == .error }) {
                    Button { project.showsLog = true; presentation.pane = "Preview" } label: { Label("Errors", systemImage: "exclamationmark.circle.fill").font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
                        .remileHelp("Compilation reported errors. Open the compiler diagnostics.")
                } else if !project.compiling, project.outputCurrent, project.pdf != nil {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(RemileStyle.success).frame(width: 24, height: 32)
                        .remileHelp("PDF matches the current source.")
                        .accessibilityLabel("PDF matches the current source")
                }
                if project.compiling { ProgressView().controlSize(.small).frame(width: 24, height: 32); Button("Stop") { project.stop() } }
                else { Button { project.compile(); presentation.pane = "Preview" } label: { HStack(alignment: .center, spacing: 6) { Image(systemName: "play.fill").font(.system(size: 13)).frame(width: 18, height: 20); Text("Compile").font(RemileType.callout.weight(.semibold)) }.frame(height: 32).foregroundStyle(RemileStyle.accent) }.keyboardShortcut(.return, modifiers: [.command]).remileHelp("Compile PDF · ⌘Return") }
                Menu { Button("Recompile from scratch") { project.compile(scratch: true); presentation.pane = "Preview" }.keyboardShortcut(.return, modifiers: [.command, .shift]); Divider(); Button("Submission check") { project.compareSubmission() } } label: { Image(systemName: "chevron.down").font(.system(size: 10)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 32).disabled(project.compiling).remileHelp("Compile options")
            }.frame(height: 32)
        }.font(RemileType.callout).buttonStyle(RemileToolStyle()).padding(.horizontal, 12).padding(.vertical, 5)
            .popover(isPresented: $project.showsSubmission, arrowEdge: .top) { TeXSubmissionPopover(project: project, check: project.submission) }
            .popover(isPresented: $project.setupNeeded, arrowEdge: .top) { TeXSetupGuide(missing: TeXConfiguration.current.missingTools(buffers: project.buffers)) }
    }
}

struct TeXSettings: View {
    @AppStorage("latex.binDirectory") private var directory = "/Library/TeX/texbin"
    @AppStorage("latex.bibliography") private var bibliography = true
    @AppStorage("latex.theme") private var theme = TeXEditorTheme.remile.rawValue
    @AppStorage("latex.fontSize") private var fontSize = 17
    @AppStorage("latex.historyMinutes") private var historyMinutes = 3
    @AppStorage("editor.toolSounds") private var toolSounds = true
    @AppStorage("editor.sidebarArtwork") private var sidebarArtwork = true
    @AppStorage("latex.engine") private var engine = TeXConfiguration.Engine.automatic.rawValue
    var body: some View {
        Form {
            Section("Editor") {
                Stepper("Source text: \(fontSize) pt", value: $fontSize, in: 10...32)
                EditorLanguageSettings()
                Stepper("History comparison: every \(historyMinutes) min", value: $historyMinutes, in: 1...30)
                Toggle("Tool completion sounds", isOn: $toolSounds)
                Picker("Theme", selection: $theme) { ForEach(TeXEditorTheme.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                Toggle("Sidebar artwork", isOn: $sidebarArtwork)
            }
            Section("AI") { AISettingsRow() }
            Section("Typesetting") {
                Picker("Engine", selection: $engine) { ForEach(TeXConfiguration.Engine.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                TextField("TeX binaries", text: $directory).textFieldStyle(.roundedBorder)
                HStack {
                    Text(TeXConfiguration.current.available ? "latexmk detected" : "latexmk not found").foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { directory = url.path } }
                }
            }
            Section("Compilation") { Toggle("Build bibliography", isOn: $bibliography); Text("Automatic selects XeLaTeX for fontspec. Builds use a source snapshot. Save writes your project.").font(RemileType.callout).foregroundStyle(.secondary) }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
}
