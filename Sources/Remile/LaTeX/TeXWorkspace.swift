import SwiftUI
import PDFKit

struct TeXWorkspace: View {
    @ObservedObject var project: TeXProject
    let close: () -> Void
    @StateObject private var editor = MarkdownEditorController()
    @StateObject private var zoom = ReaderZoom()
    @StateObject private var presentation = Presentation()
    private final class Presentation: ObservableObject { @Published var renameProject = false; @Published var renameSource = false; @Published var aiMessage: String? }
    @AppStorage("latex.fontSize") private var fontSize = 17
    @AppStorage("editor.aiSuggestions") private var aiSuggestions = false
    @AppStorage("editor.language") private var language = "Automatic"
    @AppStorage("editor.showExternalEdits") private var showExternalEdits = false
    @StateObject private var preview = TeXPDFController()
    @AppStorage("latex.theme") private var theme = TeXEditorTheme.remile.rawValue
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ReaderSplit(initial: 220, minimum: 160, maximum: 340, minimumContent: 700, label: "project files", revealToken: navigationToken, pane: {
                TeXProjectSidebar(project: project)
            }, content: {
                ReaderSplit(initial: 480, minimum: 280, maximum: 1400, minimumContent: 360, label: "LaTeX source", revealToken: navigationToken, pane: {
                    VStack(spacing: 0) {
                        HStack {
                            InlineName(value: (project.selected as NSString).lastPathComponent, editing: $presentation.renameSource) { project.rename(project.selected, to: $0) }.font(RemileType.caption).help(project.selected)
                            if project.dirty { Text("•").foregroundStyle(.secondary) }
                            Spacer()
                            Button { editor.textView?.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo").disabled(editor.textView?.undoManager?.canUndo != true)
                            Button { editor.textView?.undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("Redo").disabled(editor.textView?.undoManager?.canRedo != true)
                            Button { fontSize = max(10, fontSize - 1) } label: { Image(systemName: "minus").frame(width: 32, height: 32).contentShape(Rectangle()) }.help("Smaller source text").disabled(fontSize == 10)
                            Menu {
                                Button("Larger text") { fontSize = min(32, fontSize + 1) }.keyboardShortcut("+", modifiers: [.command, .option])
                                Button("Smaller text") { fontSize = max(10, fontSize - 1) }.keyboardShortcut("-", modifiers: [.command, .option])
                                ForEach([12, 14, 16, 17, 18, 20, 24, 28], id: \.self) { value in Button("\(value) pt") { fontSize = value } }
                            } label: { Text("\(fontSize)").monospacedDigit().font(RemileType.small) }.help("Source text size")
                            Button { fontSize = min(32, fontSize + 1) } label: { Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle()) }.help("Larger source text").disabled(fontSize == 32)
                            Button { project.syncToPDF(line: editor.selectedLine) } label: { Image(systemName: "arrow.right") }.disabled(!project.canSync).help("Show source in PDF")
                        }.buttonStyle(RemileToolStyle()).padding(.horizontal, 12).background(RemileStyle.editorBar)
                        MarkdownEditor(source: project.source, controller: editor, size: CGFloat(fontSize), serif: false, texTheme: TeXEditorTheme(rawValue: theme) ?? .remile, documentID: project.selected, externalRanges: project.externalEdits[project.selected] ?? [], showExternalEdits: showExternalEdits)
                    }
                }, content: {
                    ZStack {
                        VStack(spacing: 0) {
                            HStack {
                                Button { if let location = preview.currentLocation() { project.syncToSource(location) } } label: { Image(systemName: "arrow.left") }.disabled(!project.canSync).help("Show PDF location in source")
                                Spacer()
                                ReaderPageControl(current: preview.page, total: preview.pages, go: preview.go)
                                ReaderZoomControls(zoom: zoom)
                            }.buttonStyle(RemileToolStyle()).padding(.horizontal, 8).background(RemileStyle.editorBar)
                            if let pdf = project.pdf { TeXPDFPreview(document: pdf, zoom: zoom, controller: preview, jump: project.pdfJump) }
                            else { ContentUnavailableView("Compile to preview", systemImage: "doc.richtext").frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }.opacity(project.showsLog || project.showsHistory ? 0 : 1).allowsHitTesting(!project.showsLog && !project.showsHistory).accessibilityHidden(project.showsLog || project.showsHistory)
                        if project.showsHistory { TeXHistoryPanel(project: project) }
                        else if project.showsLog { TeXLogPanel(project: project) }
                    }
                })
            })
        }.background(RemileStyle.background)
        .navigationTitle(project.root.lastPathComponent + (project.dirty ? " •" : ""))
        .onAppear {
            editor.syncToPreview = { project.syncToPDF(line: $0) }; preview.reverse = { project.syncToSource($0) }
            project.editSource = { [weak editor = editor, weak project = project] file, before, after, name in
                guard let editor, let project, let view = editor.textView, !view.hasMarkedText() else { return false }
                project.selected = file
                editor.update(before, size: CGFloat(fontSize), serif: false, document: file)
                editor.apply(.init(range: NSRange(location: 0, length: (before as NSString).length), text: after, selection: NSRange(location: 0, length: 0)), name: name)
                return true
            }
            if !TeXConfiguration.current.missingTools(buffers: project.buffers).isEmpty { project.setupNeeded = true }
        }
        .onDisappear { project.editSource = nil }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("remile.toggleComment"))) { _ in editor.toggleComment() }
        .alert("Word suggestions", isPresented: Binding(get: { presentation.aiMessage != nil }, set: { if !$0 { presentation.aiMessage = nil } })) { Button("OK") { presentation.aiMessage = nil } } message: { Text(presentation.aiMessage ?? "") }
        .onReceive(project.$sourceJump) { jump in
            guard let jump else { return }
            editor.update(project.buffers[jump.location.file] ?? "", size: CGFloat(fontSize), serif: false, document: jump.location.file)
            editor.reveal(line: jump.location.line); editor.flash(line: jump.location.line)
        }
    }
    private var navigationToken: String { project.selected + (project.sourceJump?.id.uuidString ?? "") + (project.pdfJump?.id.uuidString ?? "") + String(project.showsLog) + String(project.showsHistory) }
    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: close) { Image(systemName: "chevron.left") }.help("Home")
            Text("LaTeX (Local)").font(RemileType.heading)
            Button { project.goBack() } label: { Image(systemName: "arrow.backward") }.disabled(project.backFiles.isEmpty).help("Back")
            Button { project.goForward() } label: { Image(systemName: "arrow.forward") }.disabled(project.forwardFiles.isEmpty).help("Forward")
            Spacer()
            if let message = project.message { Text(message).font(RemileType.caption).lineLimit(1).help(message) }
            Button {
                if aiSuggestions { aiSuggestions = false }
                else { let status = AppleIntelligence.status(); if status.ready { aiSuggestions = true } else { presentation.aiMessage = status.message } }
            } label: { Image(systemName: "sparkles").frame(width: 32, height: 32).contentShape(Rectangle()).foregroundStyle(aiSuggestions ? RemileStyle.accent : RemileStyle.ink.opacity(0.5)) }.help("Word suggestions · " + (aiSuggestions ? "On" : "Off") + " · Tab accepts")
            EditorToolsMenu(project: project, editor: editor)
            Button { showExternalEdits.toggle() } label: { Image(systemName: showExternalEdits ? "eye" : "eye.slash").frame(width: 32, height: 32).contentShape(Rectangle()).foregroundStyle(showExternalEdits ? RemileStyle.accent : RemileStyle.ink.opacity(0.5)) }.help("Show CLI edits · " + (showExternalEdits ? "On" : "Off")).accessibilityLabel("Show CLI edits").accessibilityValue(showExternalEdits ? "On" : "Off")
            Button { project.captureHistory(file: project.selected); project.showsHistory.toggle(); project.showsLog = false } label: { Image(systemName: "clock.arrow.circlepath") }.help("History")
            Button { project.showsHistory = false; project.showsLog.toggle() } label: { Image(systemName: project.showsLog ? "doc.richtext" : "terminal").frame(width: 32, height: 32).contentShape(Rectangle())
                .overlay(alignment: .topTrailing) { if !project.diagnostics.isEmpty { Text("\(project.diagnostics.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white).padding(3).background(project.diagnostics.contains { $0.severity == .error } ? RemileStyle.accent : Color(nsColor: RemileStyle.amber), in: Capsule()).offset(x: 3, y: -2).allowsHitTesting(false) } } }.help(project.showsLog ? "Show PDF" : "Build logs")
            Menu {
                Button("PDF…") { project.export() }.disabled(project.pdf == nil)
                Button("Source project (.zip)…") { project.exportSource() }
            } label: { Image(systemName: "square.and.arrow.up") }.help("Export PDF or source")
            if project.compiling { Button("Stop") { project.stop() } }
            else { Button { project.compile() } label: { Label("Compile", systemImage: "play.fill") }.keyboardShortcut(.return, modifiers: [.command]) }
            Menu {
                Button("Recompile from scratch") { project.compile(scratch: true) }.keyboardShortcut(.return, modifiers: [.command, .shift])
                Divider()
                Button("Submission check") { project.compareSubmission() }.help("Compare current and embedded bibliography source")
            } label: { Image(systemName: "chevron.down").font(.system(size: 10)).frame(width: 26, height: 32).contentShape(Rectangle()) }.disabled(project.compiling).help("Compile options")
        }.overlay(alignment: .center) {
            InlineName(value: project.root.lastPathComponent, editing: $presentation.renameProject) { project.renameProject(to: $0) }.font(RemileType.callout.weight(.medium)).frame(width: 240)
        }
        .font(RemileType.callout).buttonStyle(RemileToolStyle()).padding(.horizontal, 16).padding(.vertical, 8)
        .popover(isPresented: $project.showsSubmission, arrowEdge: .top) { TeXSubmissionPopover(project: project, check: project.submission) }
        .popover(isPresented: $project.setupNeeded, arrowEdge: .top) { TeXSetupGuide(missing: TeXConfiguration.current.missingTools(buffers: project.buffers)) }
    }
}

struct TeXSettings: View {
    @AppStorage("latex.binDirectory") private var directory = "/Library/TeX/texbin"
    @AppStorage("latex.bibliography") private var bibliography = true
    @AppStorage("latex.theme") private var theme = TeXEditorTheme.remile.rawValue
    @AppStorage("latex.fontSize") private var fontSize = 17
    @AppStorage("editor.aiSuggestions") private var aiSuggestions = false
    @AppStorage("latex.historyMinutes") private var historyMinutes = 3
    @AppStorage("editor.toolSounds") private var toolSounds = true
    @AppStorage("latex.engine") private var engine = TeXConfiguration.Engine.automatic.rawValue
    var body: some View {
        Form {
            Section("Editor") {
                Stepper("Source text: \(fontSize) pt", value: $fontSize, in: 10...32)
                EditorLanguageSettings()
                Toggle("Word suggestions (on-device)", isOn: $aiSuggestions)
                Stepper("History comparison: every \(historyMinutes) min", value: $historyMinutes, in: 1...30)
                Toggle("Tool completion sounds", isOn: $toolSounds)
                Picker("Theme", selection: $theme) { ForEach(TeXEditorTheme.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
            }
            Section("Typesetting") {
                Picker("Engine", selection: $engine) { ForEach(TeXConfiguration.Engine.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                TextField("TeX binaries", text: $directory).textFieldStyle(.roundedBorder)
                HStack {
                    Text(TeXConfiguration.current.available ? "latexmk detected" : "latexmk not found").foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { directory = url.path } }
                }
            }
            Section("Compilation") { Toggle("Build bibliography", isOn: $bibliography); Text("Automatic selects XeLaTeX for fontspec. Builds use a source snapshot; Save writes your project.").font(RemileType.callout).foregroundStyle(.secondary) }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
}
