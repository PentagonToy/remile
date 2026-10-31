import SwiftUI
import PDFKit

struct TeXWorkspace: View {
    @ObservedObject var project: TeXProject
    let close: () -> Void
    var title = "LaTeX"
    var projectTags: [OverleafWebClient.Tag] = []
    var freeOverleaf = false
    var overleafConnection: OverleafConnection?
    var reviewArchiveChanged: (OverleafThreadArchive) -> Void = { _ in }
    @MainActor init(project: TeXProject, close: @escaping () -> Void, title: String = "LaTeX", projectTags: [OverleafWebClient.Tag] = [], freeOverleaf: Bool = false, overleafConnection: OverleafConnection? = nil, reviewArchiveChanged: @escaping (OverleafThreadArchive) -> Void = { _ in }) {
        self.project = project; self.close = close; self.title = title; self.projectTags = projectTags
        self.freeOverleaf = freeOverleaf; self.overleafConnection = overleafConnection; self.reviewArchiveChanged = reviewArchiveChanged
        self._editor = StateObject(wrappedValue: project.sourceEditor)
    }
    @StateObject private var assistant = DocumentAssistant()
    @StateObject private var editor: MarkdownEditorController
    @StateObject private var writing = EditorWritingReview()
    @StateObject private var zoom = ReaderZoom()
    @StateObject private var preview = TeXPDFController()
    @StateObject private var presentation = Presentation()
    private final class Presentation: ObservableObject {
        @Published var paneReset = UUID(); @Published var evidence: ReferenceRecord?; @Published var references = false; @Published var review = false; @Published var compactTools = false; @Published var notice = false; @Published var renameProject = false; @Published var renameSource = false; @Published var files = false; @Published var pane = "Source" }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("latex.fontSize") private var fontSize = 17
    @AppStorage("editor.language") private var language = "Automatic"
    @AppStorage("editor.spellcheck") private var spellcheck = true
    @AppStorage("editor.showExternalEdits") private var showExternalEdits = false
    @AppStorage("latex.theme") private var theme = TeXEditorTheme.remile.rawValue
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            lifecycleContent
            TeXFileTabs(project: project, notice: freeOverleaf ? "Overleaf Free · Git sync unavailable" : nil) {
                presentation.review = false; presentation.files = true; presentation.paneReset = UUID()
            }
        }.focusedSceneValue(\.workspaceActions, WorkspaceActions(ask: { project.showsAssistant.toggle() }, references: { presentation.references = true }, restorePanes: { presentation.paneReset = UUID() }, logs: toggleLogs, find: { presentation.pane = "Source"; editor.find($0) }, complete: { presentation.pane = "Source"; editor.complete() }, nextTab: project.openFiles.count > 1 ? { project.cycleFileTab(forward: true) } : nil, previousTab: project.openFiles.count > 1 ? { project.cycleFileTab(forward: false) } : nil))
        .font(RemileType.control).background(RemileStyle.background).navigationTitle(project.displayName + (project.dirty ? " •" : ""))
    }
    private var workspaceContent: some View {
        ReaderSplit(side: .trailing, isPresented: project.showsAssistant, initial: 330, minimum: 240, maximum: 420, minimumContent: 400, preferPaneWhenNarrow: true, label: "LaTeX Ask", revealToken: presentation.paneReset.uuidString, pane: {
            TeXAskPanel(project: project, assistant: assistant, connection: overleafConnection, archiveRead: reviewArchiveChanged, close: { project.showsAssistant = false })
        }, content: { editorContent })
    }
    private var editorContent: some View {
        GeometryReader { geometry in
            if geometry.size.width < 820 {
                VStack(spacing: 0) {
                    HStack {
                        Button { presentation.files.toggle() } label: { SymbolLabel("Files", systemImage: "sidebar.left") }.remileHelp("Files and outline")
                            .popover(isPresented: $presentation.files) { projectSidebar.frame(width: 300, height: 520) }
                        Spacer()
                        RemileSegmentedControl(title: "Editor pane", selection: $presentation.pane, options: ["Source", "Preview"], label: { $0 }).frame(width: 190)
                    }.padding(8)
                    if presentation.pane == "Source" { sourcePane } else { previewPane }
                }
            } else {
                ReaderSplit(sizing: .files, minimum: 160, maximum: 300, minimumContent: 580, label: "project files", revealToken: navigationToken, pane: { projectSidebar }, content: {
                    GeometryReader { editorGeometry in
                        ReaderSplit(sizing: .equal, minimum: 260, maximum: max(1400, geometry.size.width), minimumContent: 280, label: "LaTeX source", revealToken: navigationToken, pane: { sourcePane }, content: { previewPane })
                    }
                })
            }
        }
    }
    private var lifecycleContent: some View {
        workspaceContent
        .task(id: project.selected + project.source.wrappedValue + language + String(spellcheck)) { await writing.check(project.source.wrappedValue, enabled: spellcheck, language: language, editor: editor) }
        .onAppear {
            if TeXEditorTheme(rawValue: theme) == nil { theme = TeXEditorTheme.remile.rawValue }
            assistant.useHistory(project.root.path)
            if let location = project.lastPreviewLocation { project.pdfJump = .init(location: location) }
            editor.inspectCitation = { [weak project = project, weak state = presentation] key in
                guard let project else { return }
                let buffers = project.buffers, library = ReferenceCitationPreferences.read(project.root.path).library
                Task { @MainActor [weak state, weak project] in
                    do {
                        let record = try await Task.detached(priority: .userInitiated) { try ReferenceEvidence.resolve(key: key, sources: buffers, library: library) }.value
                        guard let project, project.buffers == buffers else { return }
                        state?.evidence = record
                    } catch { project?.message = error.localizedDescription }
                }
            }
            editor.citationCompletion = { [weak project = project] source, range in
                guard let project else { return nil }
                if let local = await project.localCompletion.context(source, selection: range, file: project.selected, paths: project.treeFiles, buffers: project.buffers) { return local }
                return await project.citations.completion(source: source, selection: range, buffers: project.buffers)
            }
            editor.prepareCitation = { [weak project = project] item in
                guard let project else { throw ReferenceFailure("The project is no longer open.") }
                try project.citations.prepare(item, project: project)
            }
            editor.citationFailure = { [weak project = project] in project?.message = $0 }
            editor.syncToPreview = { [weak project = project, weak editor = editor] in project?.syncToPDF(line: $0, hint: editor?.sourceSyncHint) }; preview.reverse = { [weak project = project] in project?.syncToSource($0) }
            editor.proofreadRequested = { [weak writing = writing, weak editor = editor] range, view in guard let editor else { return }; writing?.proofread(range, in: view, editor: editor) }
            editor.dismissWriting = { [weak writing = writing] in writing?.dismissSuggestion() }
            project.editSource = { [weak editor = editor, weak project = project, weak state = presentation, size = CGFloat(fontSize)] file, before, after, name in
                guard let editor, let project, let view = editor.textView, !view.hasMarkedText() else { return false }
                project.selected = file; state?.pane = "Source"
                editor.update(before, size: size, serif: false, document: file)
                editor.apply(.init(range: NSRange(location: 0, length: (before as NSString).length), text: after, selection: NSRange(location: 0, length: 0)), name: name)
                return true
            }
            if !TeXConfiguration.current.missingTools(buffers: project.buffers).isEmpty { project.message = "TeX tools are missing." }
        }
        .sheet(item: $presentation.evidence) { ReferenceEvidenceView(record: $0) }
        .sheet(isPresented: $presentation.references) {
            ReferencePicker(format: .latex, insert: { record, bibliography in
                guard let view = editor.textView, !view.hasMarkedText(), project.selected.lowercased().hasSuffix(".tex"), view.string == project.source.wrappedValue else { throw ReferenceFailure("Open a TeX source file before inserting a citation.") }
                let text = try ReferenceCitation.text(record, format: .latex)
                let range = view.selectedRange()
                try project.addReference(record, bibliography: bibliography)
                editor.apply(.init(range: range, text: text, selection: NSRange(location: range.location + (text as NSString).length, length: 0)), name: "Insert citation")
            }, bibliographies: project.buffers.keys.filter { $0.lowercased().hasSuffix(".bib") }.sorted(), context: project.root.path, changed: { project.citations.invalidate() })
        }
        .onChange(of: project.compiling) { if !project.compiling { presentation.pane = "Preview" } }
        .onChange(of: project.compileFailed) { if project.compileFailed { presentation.pane = "Preview" } }
        .onChange(of: project.selected) { presentation.renameProject = false; presentation.renameSource = false; presentation.pane = "Source" }
        .animation(reduceMotion ? nil : RemileMotion.panel, value: presentation.review)
        .animation(reduceMotion ? nil : RemileMotion.panel, value: project.showsLog)
        .animation(reduceMotion ? nil : RemileMotion.panel, value: project.showsHistory)
        .onDisappear { project.lastPreviewLocation = preview.currentLocation(); assistant.cancel(); editor.suspend(); project.citations.release(); editor.inspectCitation = nil; editor.citationCompletion = nil; editor.prepareCitation = nil; editor.citationFailure = nil; project.editSource = nil; editor.syncToPreview = nil; preview.reverse = { _ in }; editor.proofreadRequested = nil; editor.dismissWriting = nil; writing.dismissSuggestion() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("remile.toggleComment"))) { event in if event.object as? TeXProject === project { editor.toggleComment() } }
        .onReceive(project.$sourceJump) { jump in
            guard let jump else { return }; presentation.pane = "Source"
            editor.update(project.buffers[jump.location.file] ?? "", size: CGFloat(fontSize), serif: false, document: jump.location.file)
            let colour = jump.highlight == .change ? NSColor(RemileStyle.success) : RemileStyle.amber
            if let range = jump.location.range, editor.reveal(range: range, colour: colour, select: jump.highlight == nil, deletion: jump.highlight == .change && range.length == 0) { }
            else { editor.reveal(line: jump.location.line); if jump.marksLine { editor.flash(line: jump.location.line, colour: colour) } }
        }
    }
    @ViewBuilder private var sourcePane: some View {
        if project.buffers[project.selected] == nil { TeXAssetPreview(project: project) }
        else { VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: RemileControl.spacing)
                Button { editor.textView?.undoManager?.undo() } label: { SymbolIcon(systemName: "arrow.uturn.backward") }.remileHelp("Undo the last source edit (⌘Z)").disabled(editor.textView?.undoManager?.canUndo != true)
                Button { editor.textView?.undoManager?.redo() } label: { SymbolIcon(systemName: "arrow.uturn.forward") }.remileHelp("Restore the last undone edit (⇧⌘Z)").disabled(editor.textView?.undoManager?.canRedo != true)
                Button { theme = theme == TeXEditorTheme.paper.rawValue ? TeXEditorTheme.remile.rawValue : TeXEditorTheme.paper.rawValue } label: { SymbolIcon(systemName: "circle.lefthalf.filled") }
                    .accessibilityLabel("Source background").accessibilityValue((TeXEditorTheme(rawValue: theme) ?? .remile).title)
                    .remileHelp(theme == TeXEditorTheme.paper.rawValue ? "Switch to the default source background" : "Switch to a paper source background")
                Menu { ForEach([12, 14, 16, 17, 18, 20, 24, 28], id: \.self) { value in Button("\(value) pt") { fontSize = value } } } label: { Text("\(fontSize)").monospacedDigit().font(RemileType.small) }.remileHelp("Text size")
                Button { project.syncToPDF(line: editor.selectedLine, hint: editor.sourceSyncHint); presentation.pane = "Preview" } label: { SymbolIcon(systemName: "arrow.right") }.disabled(!project.canSync).remileHelp("Show in PDF")
            }.buttonStyle(RemileToolStyle()).padding(.horizontal, 10).background(RemileStyle.editorBar)
            MarkdownEditor(source: project.source, controller: editor, size: CGFloat(fontSize), serif: false, texTheme: TeXEditorTheme(rawValue: theme) ?? .remile, documentID: project.selected, externalRanges: project.externalEdits[project.selected] ?? [], showExternalEdits: showExternalEdits)
        } }
    }
    private var previewPane: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button { if let location = preview.currentLocation() { project.syncToSource(location) }; presentation.pane = "Source" } label: { SymbolIcon(systemName: "arrow.left") }.disabled(!project.canSync).remileHelp("Show in source")
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
    private var projectSidebar: some View {
        VStack(spacing: 0) {
            if let overleafConnection {
                RemileSegmentedControl(title: "Project sidebar", selection: $presentation.review, options: [false, true], label: { $0 ? "Review" : "Files" }).padding(8)
                Divider()
                ZStack {
                    TeXProjectSidebar(project: project).opacity(presentation.review ? 0 : 1).allowsHitTesting(!presentation.review).accessibilityHidden(presentation.review)
                    if presentation.review { OverleafReviewPanel(project: project, connection: overleafConnection, archiveRead: reviewArchiveChanged) }
                }
            } else {
                TeXProjectSidebar(project: project)
            }
        }
    }
    private func toggleLogs() {
        project.showsLog = !(project.showsLog || project.showsHistory)
        project.showsHistory = false; presentation.pane = "Preview"
    }
    private var navigationToken: String { presentation.paneReset.uuidString + String(presentation.review) + project.selected + (project.sourceJump?.id.uuidString ?? "") + (project.pdfJump?.id.uuidString ?? "") + String(project.showsLog) + String(project.showsHistory) }
    private func noticeTitle(_ message: String) -> String {
        switch message {
        case "Check TeX references after moving or renaming a file.": return "Check TeX references"
        case let value where value.contains("EPS") || value.contains("Ghostscript"): return "Graphics conversion failed"
        case "Recompile to match source and PDF.": return "Recompile to navigate"
        case "Compile to enable source/PDF navigation.": return "Compile to navigate"
        case "Choose another main document before removing this item.": return "Choose another main document"
        case "The source changed. Prepare this action again.": return "Source changed · try again"
        default: return message.hasPrefix("Save failed:") ? "Save failed" : message.count <= 32 ? message : "Project notice"
        }
    }
    private var toolbar: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
            ZStack {
            HStack(alignment: .center, spacing: 8) {
                Button(action: close) { SymbolIcon(systemName: "chevron.left") }.remileHelp("Home")
                Text(title).font(RemileType.heading).fixedSize()
                Divider().frame(height: 18)
                Button { project.goBack() } label: { SymbolIcon(systemName: "arrow.backward") }.disabled(project.backFiles.isEmpty).remileHelp("Return to the previous source location")
                Button { project.goForward() } label: { SymbolIcon(systemName: "arrow.forward") }.disabled(project.forwardFiles.isEmpty).remileHelp("Go to the next source location")
                if geometry.size.width >= 900 {
                EditorToolsMenu(project: project, editor: editor)
                Button { showExternalEdits.toggle() } label: { SymbolIcon(systemName: showExternalEdits ? "eye" : "eye.slash") }.remileHelp(RemileHints.edits(showExternalEdits)).accessibilityLabel("Show AI and CLI edits")
                Button { project.captureHistory(file: project.selected); project.showsHistory.toggle(); project.showsLog = false; presentation.pane = "Preview" } label: { SymbolIcon(systemName: "clock.arrow.circlepath") }.remileHelp(RemileHints.history(project.showsHistory))
                } else {
                    Menu {
                        Button("Editor tools…") { presentation.compactTools = true }
                        Button(showExternalEdits ? "Hide AI and CLI edits" : "Show AI and CLI edits") { showExternalEdits.toggle() }
                        Button("History") { project.captureHistory(file: project.selected); project.showsHistory.toggle(); project.showsLog = false; presentation.pane = "Preview" }
                    } label: { SymbolIcon(systemName: "ellipsis").frame(width: RemileControl.toolHit, height: RemileControl.toolHit) }
                    .menuStyle(.borderlessButton).tint(RemileStyle.ink).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Editor options")
                    .popover(isPresented: $presentation.compactTools) { EditorToolsMenu(project: project, editor: editor).padding(12) }
                }
                let logSeverity = project.compiling ? nil : TeXDiagnostics.logSeverity(project.diagnostics, failed: project.compileFailed || project.setupNeeded || project.setupIssue != nil)
                let logLabel = logSeverity == .error ? "Build logs · Errors" : logSeverity == .warning ? "Build logs · Warnings" : "Build logs"
                let showingPanel = project.showsLog || project.showsHistory
                Button {
                    toggleLogs()
                } label: {
                    HStack(spacing: 6) {
                        SymbolIcon(systemName: showingPanel ? "doc.richtext" : "terminal").overlay(alignment: .topTrailing) {
                            if let logSeverity, !showingPanel {
                                Circle().fill(logSeverity == .error ? Color.red : Color.yellow).frame(width: RemileSymbol.statusDotSize, height: RemileSymbol.statusDotSize)
                                    .overlay(Circle().stroke(RemileStyle.editorBar, lineWidth: RemileSymbol.statusDotBorder))
                                    .offset(x: RemileSymbol.statusDotInset, y: RemileSymbol.statusDotInset).accessibilityHidden(true)
                            }
                        }
                    }
                }.remileHelp(showingPanel ? (project.pdf == nil ? "Return to PDF preview" : "Show the last successful PDF") : logLabel)
                    .accessibilityLabel(showingPanel ? "Show PDF" : logLabel)
                if geometry.size.width >= 1100 { projectName(width: min(280, max(100, geometry.size.width - 850))).frame(maxWidth: .infinity) }
                else { Spacer(minLength: 0) }
                if let message = project.message, message != "Compilation failed", message != "Edited · recompile" {
                    Button { presentation.notice.toggle() } label: { SymbolIcon(systemName: "info.circle") }.remileHelp(message)
                        .popover(isPresented: $presentation.notice) { Text(message).font(RemileType.control).padding(16).frame(width: 300).background(RemileStyle.background) }
                }
                WorkspaceAskButton(isPresented: project.showsAssistant) { project.showsAssistant.toggle() }.labelStyle(.iconOnly)
                WorkspaceReferenceButton { presentation.references = true }
                TeXExportButton(project: project).frame(height: 32).remileHelp("Export")
                if !project.compiling, project.compileFailed || project.setupNeeded || project.setupIssue != nil || project.diagnostics.contains(where: { $0.severity == .error }) {
                    Button { project.setupNeeded = false; project.showsHistory = false; project.showsLog = true; presentation.pane = "Preview" } label: { SymbolIcon(systemName: "exclamationmark.circle.fill").accessibilityLabel("Errors").font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
                        .remileHelp("Show errors")
                        .popover(isPresented: $project.setupNeeded, arrowEdge: .bottom) {
                            TeXCompileGuidance(project: project) {
                                project.setupNeeded = false; project.showsLog = true; presentation.pane = "Preview"
                            }
                        }
                } else if !project.compiling, project.outputCurrent, project.pdf != nil {
                    SymbolIcon(systemName: "checkmark.circle.fill").foregroundStyle(RemileStyle.success).frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
                        .remileHelp("PDF matches the current source.")
                        .accessibilityLabel("PDF matches the current source")
                } else if !project.compiling, project.pdf != nil, !project.outputCurrent {
                    SymbolIcon(systemName: "circle.dashed").foregroundStyle(RemileStyle.warning).frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
                        .remileHelp("Source changed. Compile to update the PDF.").accessibilityLabel("PDF needs compiling")
                }
                if project.compiling { ProgressView().controlSize(.small).frame(width: RemileControl.toolHit, height: RemileControl.toolHit); Button { project.stop() } label: { SymbolIcon(systemName: "stop.fill") }.accessibilityLabel("Stop compilation").remileHelp("Stop compilation") }
                else { Button { project.compile(); presentation.pane = "Preview" } label: { HStack(alignment: .center, spacing: 6) { SymbolIcon(systemName: "play.fill").frame(width: 18, height: 20);  }.frame(height: 32).foregroundStyle(RemileStyle.accent) }.accessibilityLabel("Compile PDF").keyboardShortcut(.return, modifiers: [.command]).remileHelp("Compile PDF · ⌘Return") }
                Menu { Button("Recompile from scratch") { project.compile(scratch: true); presentation.pane = "Preview" }.keyboardShortcut(.return, modifiers: [.command, .shift]); Divider(); Button("Submission check") { project.compareSubmission() } } label: { SymbolIcon(systemName: "chevron.down") }.menuStyle(.borderlessButton).tint(RemileStyle.ink).menuIndicator(.hidden).frame(width: RemileControl.toolHit, height: RemileControl.toolHit).disabled(project.compiling).remileHelp("Compile options").accessibilityLabel("Compile options")
            }.frame(height: 32)

            }
            }.frame(height: 32)
        }.font(RemileType.control).buttonStyle(RemileToolStyle()).padding(.horizontal, 12).padding(.vertical, 5)
            .popover(isPresented: $project.showsSubmission, arrowEdge: .top) { TeXSubmissionPopover(project: project, check: project.submission) }
    }
    private func projectName(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            OverleafTagMark(tags: projectTags)
            InlineName(value: project.displayName, editing: $presentation.renameProject, rename: { project.renameProject(to: $0) }, truncation: .tail)
        }.font(RemileType.heading).multilineTextAlignment(.leading)
            .padding(.horizontal, 12).frame(width: width, height: 30)
            .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
            .disabled(project.renamingProject)
            .accessibilityElement(children: .contain).accessibilityIdentifier("latex.project-title")
            .accessibilityAction(named: "Rename project") { presentation.renameProject = true }
            .remileHelp(project.displayName + " · double-click to rename")
    }
    private var compileErrorHint: String {
        if project.setupIssue?.managerNeedsUpdate == true { return "TeX Live Manager needs an update. Click for the update command." }
        if let issue = project.setupIssue { return "Missing TeX dependencies: " + (issue.files.isEmpty ? "Ghostscript" : issue.files.joined(separator: ", ")) + ". Click for setup commands." }
        let missing = TeXConfiguration.current.missingTools(buffers: project.buffers)
        if !missing.isEmpty { return "Missing tools: " + missing.joined(separator: ", ") + ". Click for setup help." }
        let error = TeXDiagnostics.primaryError(project.diagnostics)?.message ?? "Compilation failed."
        return error + " Click for details."
    }
}

struct TeXSettings: View {
    var project: TeXProject? = nil
    @StateObject private var environment = EnvironmentCheck()
    @MainActor private final class EnvironmentCheck: ObservableObject {
        @Published var running = false
        @Published var presented = false
        @Published var report: TeXEnvironmentReport?
        private var work: Task<TeXEnvironmentReport, Never>?
        private var generation = UUID()
        func check(_ configuration: TeXConfiguration, project: TeXProject?) {
            guard !running else { return }
            let buffers = project?.buffers, root = project?.root, files = project?.files ?? []
            running = true; presented = true; report = nil
            generation = UUID(); let token = generation
            let task = Task.detached(priority: .utility) { TeXEnvironment.check(configuration: configuration, buffers: buffers, root: root, projectFiles: files) }
            work = task
            Task { @MainActor [weak self] in
                let report = await task.value
                guard let self, self.generation == token else { return }
                self.report = report; self.running = false; self.work = nil
            }
        }
        func cancel() { work?.cancel(); work = nil; generation = UUID(); running = false }
    }

    @AppStorage("latex.binDirectory") private var directory = "/Library/TeX/texbin"
    @AppStorage("latex.bibliography") private var bibliography = true
    @AppStorage("latex.compileTimeLimit") private var compileTimeLimit = 180
    @AppStorage("latex.theme") private var theme = TeXEditorTheme.remile.rawValue
    @AppStorage("latex.fontSize") private var fontSize = 17
    @AppStorage("latex.historyMinutes") private var historyMinutes = 3
    @AppStorage("latex.lineNumbers") private var lineNumbers = true
    @AppStorage("editor.toolSounds") private var toolSounds = true
    @AppStorage("editor.sidebarArtwork") private var sidebarArtwork = true
    @AppStorage("latex.engine") private var engine = TeXConfiguration.Engine.automatic.rawValue
    var body: some View {
        Form {
            Section("Editor") {
                RemileSettingsStepper(title: "Source text", value: $fontSize, range: 10...32, formatted: "\(fontSize) pt")
                Toggle("Line numbers", isOn: $lineNumbers)
                EditorLanguageSettings()
                RemileSettingsStepper(title: "History comparison", value: $historyMinutes, range: 1...30, formatted: "Every \(historyMinutes) min")
                Toggle("Tool completion sounds", isOn: $toolSounds)
                Picker("Source background", selection: $theme) { ForEach(TeXEditorTheme.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
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
            Section {
                HStack {
                    Text("Check LaTeX Environment")
                    Spacer()
                    if environment.running { ProgressView().controlSize(.small) }
                    Button("Check") { environment.check(.current, project: project) }.disabled(environment.running)
                        .popover(isPresented: $environment.presented) {
                            TeXEnvironmentResult(report: environment.report, directory: directory)
                        }
                }
            }
            Section("Compilation") {
                Picker("Time limit", selection: $compileTimeLimit) { ForEach(TeXConfiguration.timeLimitOptions, id: \.self) { Text("\($0) seconds").tag($0) } }
                SettingsHint("Allow more time for large projects.")
                Toggle("Build bibliography", isOn: $bibliography); SettingsHint("Automatic uses XeLaTeX for fontspec.") }
        }.formStyle(.grouped).scrollContentBackground(.hidden).font(RemileType.control).toggleStyle(.switch)
            .onDisappear { environment.cancel() }
            .onChange(of: directory) { environment.cancel(); environment.report = nil; environment.presented = false }
            .onChange(of: engine) { environment.cancel(); environment.report = nil; environment.presented = false }
            .onChange(of: project?.identity) { environment.cancel(); environment.report = nil; environment.presented = false }
    }
}
