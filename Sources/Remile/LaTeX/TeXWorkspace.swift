import SwiftUI
import PDFKit

struct TeXWorkspace: View {
    @ObservedObject var project: TeXProject
    let close: () -> Void
    var title = "LaTeX"
    var projectTags: [OverleafWebClient.Tag] = []
    var freeOverleaf = false
    @StateObject private var editor = MarkdownEditorController()
    @StateObject private var writing = EditorWritingReview()
    @StateObject private var zoom = ReaderZoom()
    @StateObject private var preview = TeXPDFController()
    @StateObject private var presentation = Presentation()
    private final class Presentation: ObservableObject {
        @Published var evidence: ReferenceRecord?; @Published var references = false; @Published var review = false; @Published var compactTools = false; @Published var notice = false; @Published var renameProject = false; @Published var renameSource = false; @Published var files = false; @Published var pane = "Source" }
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
                                .popover(isPresented: $presentation.files) { projectSidebar.frame(width: 300, height: 520) }
                            Spacer()
                            Picker("Pane", selection: $presentation.pane) { Text("Source").tag("Source"); Text("Preview").tag("Preview") }.labelsHidden().pickerStyle(.segmented).frame(width: 190)
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
            ReaderThemeFooter(notice: freeOverleaf ? "Overleaf Free · Git sync unavailable" : nil, noticeHelp: "Live sync is available. Git sync requires Overleaf Premium for you or the project owner.")
        }.background(RemileStyle.background).navigationTitle(project.displayName + (project.dirty ? " •" : ""))
        .task(id: project.selected + project.source.wrappedValue + language + String(spellcheck)) { await writing.check(project.source.wrappedValue, enabled: spellcheck, language: language, editor: editor) }
        .onAppear {
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
                return await project.citations.completion(source: source, selection: range, buffers: project.buffers)
            }
            editor.prepareCitation = { [weak project = project] item in
                guard let project else { throw ReferenceFailure("The project is no longer open.") }
                try project.citations.prepare(item, project: project)
            }
            editor.citationFailure = { [weak project = project] in project?.message = $0 }
            editor.syncToPreview = { [weak project = project] in project?.syncToPDF(line: $0) }; preview.reverse = { [weak project = project] in project?.syncToSource($0) }
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
        .onChange(of: project.selected) { presentation.renameProject = false; presentation.renameSource = false; if project.buffers[project.selected] == nil { presentation.pane = "Source" } }
        .onDisappear { editor.suspend(); project.citations.release(); editor.inspectCitation = nil; editor.citationCompletion = nil; editor.prepareCitation = nil; editor.citationFailure = nil; project.editSource = nil; editor.syncToPreview = nil; preview.reverse = { _ in }; editor.proofreadRequested = nil; editor.dismissWriting = nil; writing.dismissSuggestion() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("remile.toggleComment"))) { event in if event.object as? TeXProject === project { editor.toggleComment() } }
        .onReceive(project.$sourceJump) { jump in
            guard let jump else { return }; presentation.pane = "Source"
            editor.update(project.buffers[jump.location.file] ?? "", size: CGFloat(fontSize), serif: false, document: jump.location.file)
            if let range = jump.location.range, editor.reveal(range: range) { }
            else { editor.reveal(line: jump.location.line); editor.flash(line: jump.location.line) }
        }
    }
    @ViewBuilder private var sourcePane: some View {
        let sourceFile = project.selected
        if project.buffers[project.selected] == nil { TeXAssetPreview(project: project) }
        else { VStack(spacing: 0) {
            HStack(spacing: 6) {
                InlineName(value: (sourceFile as NSString).lastPathComponent, editing: $presentation.renameSource) { project.rename(sourceFile, to: $0) }.font(RemileType.caption).frame(maxWidth: .infinity, alignment: .leading)
                if project.dirty { Text("•").foregroundStyle(.secondary) }
                Button { editor.textView?.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }.remileHelp("Undo the last source edit (⌘Z)").disabled(editor.textView?.undoManager?.canUndo != true)
                Button { editor.textView?.undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }.remileHelp("Restore the last undone edit (⇧⌘Z)").disabled(editor.textView?.undoManager?.canRedo != true)
                Menu { ForEach([12, 14, 16, 17, 18, 20, 24, 28], id: \.self) { value in Button("\(value) pt") { fontSize = value } } } label: { Text("\(fontSize)").monospacedDigit().font(RemileType.small) }.remileHelp("Text size")
                Button { project.syncToPDF(line: editor.selectedLine); presentation.pane = "Preview" } label: { Image(systemName: "arrow.right") }.disabled(!project.canSync).remileHelp("Show in PDF")
            }.buttonStyle(RemileToolStyle()).padding(.horizontal, 10).background(RemileStyle.editorBar)
            MarkdownEditor(source: project.source, controller: editor, size: CGFloat(fontSize), serif: false, texTheme: TeXEditorTheme(rawValue: theme) ?? .remile, documentID: project.selected, externalRanges: project.externalEdits[project.selected] ?? [], showExternalEdits: showExternalEdits)
        } }
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
    private var projectSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("Files") { presentation.review = false }.font(RemileType.caption.weight(presentation.review ? .regular : .semibold))
                Button("Review") { presentation.review = true }.font(RemileType.caption.weight(presentation.review ? .semibold : .regular))
                Spacer(minLength: 0)
            }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            ZStack {
                TeXProjectSidebar(project: project).opacity(presentation.review ? 0 : 1).allowsHitTesting(!presentation.review).accessibilityHidden(presentation.review)
                if presentation.review { ManuscriptReviewPanel(project: project) }
            }
        }
    }
    private var navigationToken: String { String(presentation.review) +  project.selected + (project.sourceJump?.id.uuidString ?? "") + (project.pdfJump?.id.uuidString ?? "") + String(project.showsLog) + String(project.showsHistory) }
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
                    HStack(spacing: 10) {
                        Button(action: close) { Image(systemName: "chevron.left") }.remileHelp("Home")
                        Text(title).font(RemileType.callout.weight(.semibold)).lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                        if let message = project.message, message != "Compilation failed", message != "Edited · recompile" {
                            Button { presentation.notice.toggle() } label: { Text(noticeTitle(message)).font(RemileType.caption).fixedSize(horizontal: true, vertical: false) }
                                .buttonStyle(.plain).remileHelp(message)
                                .popover(isPresented: $presentation.notice) { Text(message).font(RemileType.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(16).frame(width: 300, alignment: .leading).background(RemileStyle.background) }
                        }
                    }

                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(height: 32)
            GeometryReader { geometry in
            ZStack {
            HStack(alignment: .center, spacing: 8) {
                Button { project.goBack() } label: { Image(systemName: "arrow.backward") }.disabled(project.backFiles.isEmpty).remileHelp("Return to the previous source location")
                Button { project.goForward() } label: { Image(systemName: "arrow.forward") }.disabled(project.forwardFiles.isEmpty).remileHelp("Go to the next source location")
                Button {
                    presentation.review.toggle()
                    if geometry.size.width < 820 { presentation.files = true }
                } label: { Label("Review", systemImage: "doc.text.magnifyingglass") }
                    .accessibilityLabel("Manuscript review").remileHelp("Questions to consider before submission").frame(height: 32)
                if geometry.size.width >= 900 {
                EditorToolsMenu(project: project, editor: editor)
                Button { showExternalEdits.toggle() } label: { Image(systemName: showExternalEdits ? "eye" : "eye.slash") }.remileHelp(RemileHints.edits(showExternalEdits)).accessibilityLabel("Show AI and CLI edits")
                Button { project.captureHistory(file: project.selected); project.showsHistory.toggle(); project.showsLog = false; presentation.pane = "Preview" } label: { Image(systemName: "clock.arrow.circlepath") }.remileHelp(RemileHints.history(project.showsHistory))
                } else {
                    Menu {
                        Button("Editor tools…") { presentation.compactTools = true }
                        Button(showExternalEdits ? "Hide AI and CLI edits" : "Show AI and CLI edits") { showExternalEdits.toggle() }
                        Button("History") { project.captureHistory(file: project.selected); project.showsHistory.toggle(); project.showsLog = false; presentation.pane = "Preview" }
                    } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Editor options")
                    .popover(isPresented: $presentation.compactTools) { EditorToolsMenu(project: project, editor: editor).padding(12) }
                }
                let logSeverity = project.compiling ? nil : TeXDiagnostics.logSeverity(project.diagnostics, failed: project.compileFailed || project.setupNeeded || project.setupIssue != nil)
                let logLabel = logSeverity == .error ? "Build logs · Errors" : logSeverity == .warning ? "Build logs · Warnings" : "Build logs"
                Button { project.showsHistory = false; project.showsLog = true; presentation.pane = "Preview" } label: {
                    Image(systemName: "terminal").overlay(alignment: .top) {
                        if let logSeverity {
                            Circle().fill(logSeverity == .error ? Color.red : Color.yellow).frame(width: 6, height: 6)
                                .overlay(Circle().stroke(RemileStyle.editorBar, lineWidth: 1)).offset(y: -7).accessibilityHidden(true)
                        }
                    }
                }.remileHelp(logLabel).accessibilityLabel(logLabel)
                Button { project.showsLog = false; project.showsHistory = false; presentation.pane = "Preview" } label: { Image(systemName: "doc.richtext") }
                    .remileHelp(project.pdf == nil ? "Compile to create a PDF" : "Show the last successful PDF").accessibilityLabel("Show PDF")
                Button { presentation.references = true } label: { Image(systemName: "books.vertical") }.remileHelp("Reference library").accessibilityLabel("Reference library")
                Spacer(minLength: 0)
                TeXExportButton(project: project).frame(width: 32, height: 32).remileHelp("Export")
                if !project.compiling, project.compileFailed || project.setupNeeded || project.setupIssue != nil || project.diagnostics.contains(where: { $0.severity == .error }) {
                    Button { project.setupNeeded = false; project.showsHistory = false; project.showsLog = true; presentation.pane = "Preview" } label: { Image(systemName: "exclamationmark.circle.fill").accessibilityLabel("Errors").font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
                        .remileHelp("Show errors")
                        .popover(isPresented: $project.setupNeeded, arrowEdge: .bottom) {
                            TeXCompileGuidance(project: project) {
                                project.setupNeeded = false; project.showsLog = true; presentation.pane = "Preview"
                            }
                        }
                } else if !project.compiling, project.outputCurrent, project.pdf != nil {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(RemileStyle.success).frame(width: 24, height: 32)
                        .remileHelp("PDF matches the current source.")
                        .accessibilityLabel("PDF matches the current source")
                } else if !project.compiling, project.pdf != nil, !project.outputCurrent {
                    Image(systemName: "circle.dashed").font(.system(size: 14)).foregroundStyle(RemileStyle.warning).frame(width: 24, height: 32)
                        .remileHelp("Source changed. Compile to update the PDF.").accessibilityLabel("PDF needs compiling")
                }
                if project.compiling { ProgressView().controlSize(.small).frame(width: 24, height: 32); Button("Stop") { project.stop() } }
                else { Button { project.compile(); presentation.pane = "Preview" } label: { HStack(alignment: .center, spacing: 6) { Image(systemName: "play.fill").font(.system(size: 13)).frame(width: 18, height: 20); if geometry.size.width >= 900 { Text("Compile").font(RemileType.callout.weight(.semibold)) } }.frame(height: 32).foregroundStyle(RemileStyle.accent) }.keyboardShortcut(.return, modifiers: [.command]).remileHelp("Compile PDF · ⌘Return") }
                Menu { Button("Recompile from scratch") { project.compile(scratch: true); presentation.pane = "Preview" }.keyboardShortcut(.return, modifiers: [.command, .shift]); Divider(); Button("Submission check") { project.compareSubmission() } } label: { Image(systemName: "chevron.down").font(.system(size: 10)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 32).disabled(project.compiling).remileHelp("Compile options")
            }.frame(height: 32)
                HStack(spacing: 6) {
                    OverleafTagMark(tags: projectTags)
                    InlineName(value: project.displayName, editing: $presentation.renameProject, rename: { project.renameProject(to: $0) }, truncation: .tail)
                }
                    .font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.leading)
                    .frame(width: min(340, max(100, geometry.size.width - (geometry.size.width >= 900 ? 660 : 360))), alignment: .center)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                    .disabled(project.renamingProject)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("latex.project-title")
                    .accessibilityAction(named: "Rename project") { presentation.renameProject = true }
                    .remileHelp(project.displayName + " · double-click to rename")
            }
            }.frame(height: 32)
        }.font(RemileType.callout).buttonStyle(RemileToolStyle()).padding(.horizontal, 12).padding(.vertical, 5)
            .popover(isPresented: $project.showsSubmission, arrowEdge: .top) { TeXSubmissionPopover(project: project, check: project.submission) }
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
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .onDisappear { environment.cancel() }
            .onChange(of: directory) { environment.cancel(); environment.report = nil; environment.presented = false }
            .onChange(of: engine) { environment.cancel(); environment.report = nil; environment.presented = false }
            .onChange(of: project?.identity) { environment.cancel(); environment.report = nil; environment.presented = false }
    }
}
