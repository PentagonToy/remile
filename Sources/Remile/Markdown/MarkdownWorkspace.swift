import SwiftUI
import UniformTypeIdentifiers

struct MarkdownWorkspace: View {
    enum Mode: String, CaseIterable, Identifiable {
        case read = "Read", edit = "Edit", split = "Split"
        var id: Self { self }
    }
    @Binding var source: String
    var session: ReadingSession?
    var fileURL: URL?
    @StateObject private var presentation: Presentation
    @StateObject private var zoom = ReaderZoom(text: true)
    @StateObject private var editor = MarkdownEditorController()
    @StateObject private var assistant = DocumentAssistant()
    @StateObject private var writing = EditorWritingReview()
    @AppStorage("markdown.spellcheck") private var spellcheck = true
    @AppStorage("editor.language") private var language = "Automatic"
    @StateObject private var preview = MarkdownPreviewModel()
    @AppStorage("editor.showExternalEdits") private var showExternalEdits = false
    @AppStorage("editor.focusMode") private var focusMode = false
    @AppStorage("markdown.livePreview") private var livePreview = true
    @AppStorage("markdown.fontSize") private var fontSize = 18.0
    @AppStorage("reader.markdownSerif") private var serif = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(source: Binding<String>, mode: Mode = .read, fileURL: URL? = nil, session: ReadingSession? = nil) {
        _source = source; _presentation = StateObject(wrappedValue: Presentation(mode: mode)); self.fileURL = fileURL; self.session = session
    }
    final class Presentation: ObservableObject {
        @Published var mode: Mode
        @Published var outline = false
        @Published var expanded = true
        @Published var settings = false
        @Published var table: MarkdownTableEditor.State?
        @Published var printing = false
        @Published var ask = false
        @Published var error: String?
        init(mode: Mode) { self.mode = mode }
    }
    private var editorView: some View { MarkdownEditor(source: $source, controller: editor, size: min(32, max(11, fontSize)), serif: serif, documentID: fileURL?.path, externalRanges: session?.externalEdits ?? [], showExternalEdits: showExternalEdits) }
    private var previewView: some View { MarkdownPreview(source: source, scale: zoom.scale, wide: zoom.wide, fileURL: fileURL, serif: serif, model: preview) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Markdown").font(RemileType.heading)
                Spacer()
                if presentation.mode == .split {
                    Button { preview.revealSource() } label: { Image(systemName: "arrow.left") }.remileHelp("Show preview selection in source")
                    Button { preview.reveal(line: editor.selectedLine) } label: { Image(systemName: "arrow.right") }.remileHelp("Show source in preview")
                }
                AIToolGroup {
                AIProviderButton()
                Button { presentation.ask.toggle() } label: { Image(systemName: "text.bubble") }.remileHelp("Ask about document").accessibilityLabel("Ask about document")
                EditorWritingReviewButton(review: writing, editor: editor)
                }

                Button { showExternalEdits.toggle() } label: { Image(systemName: showExternalEdits ? "eye" : "eye.slash") }.remileHelp(RemileHints.edits(showExternalEdits)).accessibilityLabel("Show AI and CLI edits")
                Menu { Toggle("Focus paragraph", isOn: $focusMode); Button("Editor settings…") { presentation.settings = true } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().remileHelp("Focus mode and editor settings")
                Button { render() } label: { Label("Render", systemImage: "arrow.clockwise") }.keyboardShortcut(.return, modifiers: [.command])
            }.font(RemileType.callout).buttonStyle(RemileToolStyle()).padding(.horizontal, 16).padding(.vertical, 6).background(RemileStyle.editorBar)
            Divider()
            Group {
                if presentation.outline {
                    ReaderSplit(initial: 220, minimum: 180, maximum: 300, minimumContent: 580, label: "outline", pane: { outlinePanel }, content: { documentContent })
                } else { documentContent }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 14) {
                Text(presentation.mode == .read ? "Reading" : "Markdown source")
                Spacer()
                if presentation.printing { ProgressView().controlSize(.small); Text("Preparing print…") }
                Text("\(preview.wordCount) words")
                Text("UTF-8").monospaced()
                ReaderThemeButton()
            }.font(RemileType.caption).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 32).background(RemileStyle.editorBar)
        }
        .sheet(isPresented: $presentation.settings) { VStack(alignment: .trailing, spacing: 0) { MarkdownSettings(); Button("Done") { presentation.settings = false }.keyboardShortcut(.defaultAction).padding([.horizontal, .bottom], 20) }.background(RemileStyle.background) }
        .sheet(isPresented: Binding(get: { presentation.table != nil }, set: { if !$0 { presentation.table = nil } })) {
            if let state = presentation.table { MarkdownTableEditor(state: state, apply: { editor.applyTable($0, expected: state.source) }, close: { presentation.table = nil }) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("remile.exportMarkdownPDF"))) { event in if event.object as? ReadingSession === session { exportPDF() } }
        .tint(DocumentTone.accent(pdf: false))
        .animation(reduceMotion ? nil : RemileMotion.panel, value: presentation.outline)
        .task(id: source + String(spellcheck) + language) { await writing.check(source, enabled: spellcheck, language: language, editor: editor) }
        .task(id: source) { if livePreview || preview.html == nil { await preview.render(source, url: previewURL) } }
        .onChange(of: livePreview) { if livePreview { render() } }
        .onDisappear { session?.editSource = nil; writing.dismissSuggestion(); editor.synonymsRequested = nil; editor.proofreadRequested = nil; editor.writingIssueRequested = nil; editor.dismissWriting = nil }
        .onAppear {
            assistant.useHistory(fileURL?.path)
            editor.synonymsRequested = { [weak writing = writing, weak editor = editor] range, view in guard let editor else { return }; _ = writing?.showSuggestion(at: range, in: view, editor: editor, synonymsOnly: true) }
            editor.proofreadRequested = { [weak writing = writing, weak editor = editor] range, view in guard let editor else { return }; writing?.proofread(range, in: view, editor: editor) }
            editor.writingIssueRequested = { [weak writing = writing, weak editor = editor] range, view in guard let editor else { return false }; return writing?.showSuggestion(at: range, in: view, editor: editor) ?? false }
            editor.dismissWriting = { [weak writing = writing] in writing?.dismissSuggestion() }
            session?.editSource = { [weak editor = editor, weak state = presentation, weak session = session] before, after in
                guard let session, case .markdown(let current) = session.document.content, current == before else { return false }
                state?.mode = .split
                try? await Task.sleep(for: .milliseconds(100))
                guard let editor, let view = editor.textView, view.window != nil, view.string == before else { return false }
                editor.apply(.init(range: NSRange(location: 0, length: (before as NSString).length), text: after, selection: NSRange(location: 0, length: 0)), name: "CLI edit")
                return view.string == after
            }
            preview.sourceSelection = { [weak editor = editor, weak state = presentation] line, text in state?.mode = .split; editor?.reveal(line: line, text: text) }
            editor.syncToPreview = { [weak preview = preview, weak state = presentation] line in state?.mode = .split; preview?.reveal(line: line) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("remile.print"))) { event in if event.object as? ReadingSession === session { printDocument() } }
        .alert("Unable to export or print", isPresented: Binding(get: { presentation.error != nil }, set: { if !$0 { presentation.error = nil } })) {
            Button("OK") { presentation.error = nil }
        } message: { Text(presentation.error ?? "") }
        .toolbar {
            ToolbarItem(placement: .navigation) { Button { presentation.outline.toggle() } label: { Label("Outline", systemImage: "list.bullet.indent") }.remileHelp("Show document outline") }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { ReaderZoomControls(zoom: zoom, text: true) }.sharedBackgroundVisibility(.hidden)
            } else { ToolbarItem(placement: .primaryAction) { ReaderZoomControls(zoom: zoom, text: true) } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Bold") { editor.wrap("**", "**", name: "Bold") }.keyboardShortcut("b")
                    Button("Italic") { editor.wrap("*", "*", name: "Italic") }.keyboardShortcut("i")
                    Button("Inline code") { editor.wrap("`", "`", name: "Code") }
                    Button("Link") { editor.wrap("[", "](https://)", name: "Link") }.keyboardShortcut("k")
                    Divider()
                    Button("Heading") { editor.prefix("## ", name: "Heading") }
                    Button("Bullet list") { editor.prefix("- ", name: "List") }
                    Button("Task list") { editor.prefix("- [ ] ", name: "Task List") }
                    Button("Quote") { editor.prefix("> ", name: "Quote") }
                    Button("Insert or edit table…") { if let table = editor.table() { presentation.table = .init(table: table, source: source) } }
                    Button("Paste as Markdown") { editor.pasteMarkdown() }.keyboardShortcut("v", modifiers: [.command, .shift])
                    Button("Math block") { editor.wrap("$$\n", "\n$$", name: "Math") }
                    Button("Code block") { editor.wrap("```\n", "\n```", name: "Code Block") }
                } label: { Label("Format", systemImage: "textformat") }.disabled(presentation.mode == .read)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if presentation.mode == .read { presentation.mode = .edit }
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(60)); editor.find() }
                } label: { Label("Find", systemImage: "magnifyingglass") }.keyboardShortcut("f")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Document mode", selection: $presentation.mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 225)
            }
        }
    }
    private var outlinePanel: some View {
        VStack(spacing: 0) {
            DisclosureGroup("Outline", isExpanded: $presentation.expanded) { EmptyView() }.font(RemileType.callout.weight(.semibold)).padding(12)
            Divider()
            if presentation.expanded {
                if preview.sections.isEmpty { Text("No headings in this file").font(RemileType.small).foregroundStyle(.secondary).padding(12) }
                else { ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(preview.sections, id: \.number) { section in
                            Button { editor.reveal(line: section.line); preview.reveal(section: section.number) } label: {
                                Text(section.title).font(RemileType.callout).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            }.buttonStyle(.plain)
                        }
                    }.padding(4)
                } }
            }
            if !presentation.expanded || preview.sections.isEmpty { Spacer(minLength: 0) }
            Divider()
            EditorSidebarFooter(compact: presentation.expanded, title: "Editor settings") { presentation.settings = true }
        }.frame(maxHeight: .infinity, alignment: .top).background(RemileStyle.sidebar)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: presentation.expanded)
    }
    @ViewBuilder private var documentContent: some View {
        if presentation.ask {
            ReaderSplit(side: .trailing, initial: 330, minimum: 240, maximum: 420, minimumContent: 280, preferPaneWhenNarrow: true, label: "Markdown Ask", pane: {
                AssistantPanel(assistant: assistant, passages: [], topic: fileURL?.deletingPathExtension().lastPathComponent ?? "this document", select: { item in editor.reveal(line: item.location.unit); presentation.ask = false }, close: { presentation.ask = false }, retrieve: { question in
                    let lines = source.components(separatedBy: "\n")
                    let passages = stride(from: 0, to: lines.count, by: 16).map { index in AssistantPassage(location: .init(path: fileURL?.path ?? "Untitled.md", unit: index + 1, label: "Line \(index + 1)"), text: lines[index..<min(lines.count, index + 16)].joined(separator: "\n")) }
                    return AssistantRetrieval.rank(passages, question: question)
                })
            }, content: { plainDocumentContent })
        } else { plainDocumentContent }
    }
    @ViewBuilder private var plainDocumentContent: some View {
        switch presentation.mode {
        case .read: previewView
        case .edit: editorView
        case .split:
            ReaderSplit(initial: 430, minimum: 280, maximum: 1200, minimumContent: 280, preferPaneWhenNarrow: true, label: "Markdown editor", pane: { editorView }, content: { previewView })
        }
    }
    private var previewURL: URL { fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Untitled.md") }
    private func render() { preview.retryRemoteImages(); Task { @MainActor in await preview.render(source, url: previewURL) } }
    private func exportPDF() {
        guard !presentation.printing else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".pdf"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        presentation.printing = true
        let snapshot = source, url = previewURL
        Task { @MainActor in
            defer { presentation.printing = false }
            do {
                let html = try await Task.detached { var renderer = MarkdownHTML(baseURL: url); return try renderer.document(snapshot) }.value
                try await MarkdownPDF.write(html, to: output)
            } catch { presentation.error = error.localizedDescription }
        }
    }
    private func printDocument() {
        guard !presentation.printing else { return }; presentation.printing = true
        let source = source, url = fileURL
        Task { @MainActor in
            defer { presentation.printing = false }
            do { try await MarkdownPrinting.run(source: source, fileURL: url) }
            catch { presentation.error = error.localizedDescription }
        }
    }
}
