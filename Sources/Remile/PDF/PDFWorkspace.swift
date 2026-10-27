import SwiftUI
import PDFKit

struct PDFWorkspace: View {
    let data: Data
    var fileURL: URL? = nil
    var readingSession: ReadingSession? = nil
    @ObservedObject private var navigation = ReaderNavigation.shared
    let updateDocument: (Data) -> Void
    @StateObject private var session = PDFSession()
    @StateObject private var assistant = DocumentAssistant()
    @StateObject private var presentation = Presentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("assistant.provider") private var assistantProvider = "Apple Intelligence"
    private let assistantContext = PDFAssistantContext()
    private final class Presentation: ObservableObject {
        @Published var ask = false
        @Published var selectedPassages: [AssistantPassage] = []
        @Published var translation: SelectionTranslation?
        @Published var ocr = false
        let untitledPath = "/remile-untitled-" + UUID().uuidString + "/Untitled.pdf"
    }
    @Environment(\.undoManager) private var undoManager
    @FocusState private var searchFocused: Bool
    @StateObject private var zoom = ReaderZoom()

    init(data: Data, fileURL: URL? = nil, session: PDFSession? = nil, showAsk: Bool = false, readingSession: ReadingSession? = nil, updateDocument: @escaping (Data) -> Void) {
        self.data = data; self.fileURL = fileURL; self.readingSession = readingSession; self.updateDocument = updateDocument
        _session = StateObject(wrappedValue: session ?? PDFSession())
        let state = Presentation(); state.ask = showAsk
        _presentation = StateObject(wrappedValue: state)
    }

    var body: some View {
        VStack(spacing: 0) {
            readingHeader
            readingColumns.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            if let message = session.citationStatus {
                HStack {
                    Text(message).font(RemileType.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { session.dismissCitationStatus() }
                }.padding(10).background(RemileStyle.editorBar)
            }
            PDFDocumentTabs(reader: readingSession)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { readingSession?.pdfSession = session; readingSession?.pdfInspection = { [weak session = session] page, find, render in guard let session, let document = session.document else { throw CocoaError(.fileReadUnknown) }; return try PDFInspection.read(document, page: page ?? max(1, session.currentPage), find: find, render: render) }; readingSession?.commentsExport = { [weak session = session] in guard let session else { throw CocoaError(.fileReadUnknown) }; return try session.exportComments(name: fileURL?.lastPathComponent ?? "Untitled.pdf") }; assistant.useHistory(fileURL.map { "pdf:" + $0.path }); session.undoManager = undoManager; session.readingURL = fileURL; session.load(data); session.loadComments(); revealLibraryPage(); if !session.query.isEmpty { session.search() } }
        .onChange(of: data) { _, data in assistant.cancel(); presentation.selectedPassages = []; session.load(data) }
        .onChange(of: fileURL) { assistant.useHistory(fileURL.map { "pdf:" + $0.path }) }
        .onChange(of: navigation.request?.id) { revealLibraryPage() }
        .onDisappear { session.persistReadingPosition(); assistant.cancel(); session.stop(); session.protection.finish(); readingSession?.commentsExport = nil; readingSession?.pdfInspection = nil; readingSession?.pdfSession = nil }
        .onChange(of: session.query) { session.search() }
        .onChange(of: session.caseSensitive) { session.search() }
        .onChange(of: session.pendingAnnotationRevision) { readingSession?.objectWillChange.send() }
        .onChange(of: session.committedData) { _, bytes in if let bytes { assistant.cancel(); updateDocument(bytes) } }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("remile.print"))) { event in if event.object as? ReadingSession === readingSession { session.printDocument() } }
        .modifier(SelectionTranslationModifier(request: $presentation.translation))
        .sheet(isPresented: $presentation.ocr) { PDFDocumentOCRSheet(data: session.committedData ?? data, password: session.assistantPassword) }
    }

    // Keep the PDFReader at a stable structural position when either pane opens.
    private var readingColumns: some View {
        ReaderSplit(sizing: .sidebar, isPresented: session.showsSidebar, minimum: ReaderSidebar.minimum, maximum: ReaderSidebar.maximum, minimumContent: presentation.ask ? 720 : 380, label: "document sidebar", pane: { sidebar }, content: { readingAndAsk })
    }
    private var readingAndAsk: some View {
        ReaderSplit(side: .trailing, isPresented: presentation.ask, initial: 360, minimum: 320, maximum: 440, minimumContent: 380, preferPaneWhenNarrow: true, label: "Ask panel", pane: { assistantPanel }, content: { readingCanvas })
    }
    private var readingCanvas: some View {
        Group {
            if let document = session.document, !document.isLocked {
                if session.showsOverview {
                    PDFThumbnailOverview(session: session)
                } else {
                    PDFReader(session: session, zoom: zoom, selectionActions: selectionActions)
                }
            } else if session.document?.isLocked == true {
                VStack(spacing: 16) {
                    SymbolIcon(systemName: "lock.doc", slot: RemileSymbol.emptySlot).font(.system(size: RemileSymbol.emptySize)).foregroundStyle(.secondary)
                    Text("Unlock this PDF").font(RemileType.heading)
                    SecureField("Password", text: $session.password)
                        .textFieldStyle(.roundedBorder).frame(width: 260).onSubmit { session.unlock() }
                    if let error = session.passwordError { Text(error).foregroundStyle(.red).font(RemileType.callout) }
                    Button("Unlock") { session.unlock() }.buttonStyle(.borderedProminent).disabled(session.password.isEmpty)
                }
            } else {
                ContentUnavailableView("Unable to open PDF", systemImage: "exclamationmark.triangle", description: Text("The document may be damaged or unsupported."))
            }
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
    private var assistantPanel: some View {
        AssistantPanel(assistant: assistant, passages: [], topic: fileURL?.deletingPathExtension().lastPathComponent ?? "this PDF", select: { source in
            let location = source.location
            guard location.path == assistantPath else { return }
            session.revealLibraryPage(location.unit, terms: [], excerpt: source.text)
        }, close: { toggleAssistant() }, retrieve: { question in
            guard session.document?.allowsCopying == true, session.document?.isLocked == false else { throw PDFAssistantContext.Failure.restricted }
            let retrieved = try await assistantContext.passages(data: session.committedData ?? data, password: session.assistantPassword, path: assistantPath, question: question,
                currentPage: session.currentPage, selection: presentation.selectedPassages.first.map { (page: $0.location.unit, text: $0.text) } ?? session.assistantSelection, expanded: assistantProvider == "ChatGPT" && AIUsage.shared.reason == nil) { fraction in
                    await assistant.reportProgress(fraction)
                }
            return presentation.selectedPassages + retrieved.filter { passage in !presentation.selectedPassages.contains { $0.id == passage.id } }
        }, selection: presentation.selectedPassages.isEmpty ? nil : presentation.selectedPassages.map(\.text).joined(separator: "\n"), clearSelection: { presentation.selectedPassages = [] }).transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var readingHeader: some View {
        VStack(spacing: 0) {
            readingControls
            Divider()
            if session.isEditing || session.showsOverview || session.editingError != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if session.isEditing || session.showsOverview { editingStrip.transition(.opacity) }
                    if let error = session.editingError {
                        HStack {
                            SymbolIcon(systemName: "exclamationmark.circle").foregroundStyle(.red)
                            Text(error).font(RemileType.callout)
                            Spacer()
                            Button { session.dismissEditingError() } label: { SymbolIcon(systemName: "xmark") }.buttonStyle(.plain).remileHelp("Dismiss message")
                        }.padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    Divider()
                }.background(RemileStyle.editorBar)
            }
        }.background(RemileStyle.editorBar)
    }


    private var readingControls: some View {
        GeometryReader { geometry in
            readingControlRow(compact: geometry.size.width < 1000)
        }.frame(height: 32).padding(.horizontal, 16).padding(.vertical, 6)
    }
    private func readingControlRow(compact: Bool) -> some View {
        HStack(spacing: RemileControl.spacing) {
            Button { withAnimation(reduceMotion ? nil : RemileMotion.panel) { session.showsSidebar.toggle() } } label: { SymbolIcon(systemName: "sidebar.left") }.remileHelp("Pages, outline, search and comments").accessibilityLabel("Document sidebar").accessibilityValue(session.showsSidebar ? "Shown" : "Hidden")
            HStack(spacing: 6) {
                if !compact { Button { session.previousPage() } label: { SymbolIcon(systemName: "chevron.up") }.remileHelp("Previous page").disabled(session.showsOverview || session.currentPage <= 1) }
                ReaderPageControl(current: session.currentPage, total: session.document?.pageCount ?? 0, go: session.goToPage)
                if !compact { Button { session.nextPage() } label: { SymbolIcon(systemName: "chevron.down") }.remileHelp("Next page").disabled(session.showsOverview || session.currentPage >= (session.document?.pageCount ?? 0)) }
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    if session.showsOverview, let page = session.document?.page(at: max(0, session.currentPage - 1)) { session.openOverviewPage(page) }
                    else {
                        session.selectedOverviewPages = Set(session.document?.page(at: max(0, session.currentPage - 1)).map { [ObjectIdentifier($0)] } ?? [])
                        session.showsOverview = true
                    }
                }
            } label: { SymbolIcon(systemName: session.showsOverview ? "doc.text" : "square.grid.2x2") }
                .remileHelp(session.showsOverview ? "Read document" : "Page overview").accessibilityLabel(session.showsOverview ? "Read document" : "Page overview").accessibilityValue(session.showsOverview ? "Overview" : "Reading")
                .disabled(session.document?.isLocked != false)
            Button { session.firstPageAlone = false; session.twoPage.toggle() } label: {
                SymbolIcon(systemName: session.twoPage ? "rectangle.split.2x1" : "rectangle")
                    .frame(width: 22)
            }.remileHelp(session.twoPage ? "Show one page" : "Show two pages")
                .accessibilityLabel("Page layout").accessibilityValue(session.twoPage ? "Two pages" : "Single page")
                .disabled(session.document == nil || session.showsOverview)

            Spacer(minLength: 12)
            PDFProtectionButton(protection: session.protection, unlock: session.requestEditingUnlock)
            Button { presentation.ocr = true } label: { controlLabel("Scan & OCR", symbol: "text.viewfinder", compact: compact) }.remileHelp("Recognise text throughout this PDF with Apple Vision").disabled(session.document?.allowsCopying != true || session.document?.isLocked != false)
            Button { withAnimation(reduceMotion ? nil : RemileMotion.panel) { session.toggleEditing() } } label: { controlLabel(session.isEditing ? "Done" : "Edit PDF", symbol: session.isEditing ? "checkmark" : "square.and.pencil", compact: compact) }.remileHelp(session.isEditing ? "Finish editing PDF" : "Edit PDF text, annotations and pages").disabled(session.document == nil)
            AIToolGroup {
            AIProviderButton()
            Button { toggleAssistant() } label: { SymbolIcon(systemName: "text.bubble") }.remileHelp(assistantProvider == "ChatGPT" ? "Ask ChatGPT" : "Ask (on-device)").accessibilityLabel(assistantProvider == "ChatGPT" ? "Ask ChatGPT" : "Ask (on-device)").disabled(session.document?.allowsCopying != true || session.document?.isLocked != false)

            }
            if compact {
                Menu {
                    Button("Zoom in") { zoom.step(1) }.disabled(session.showsOverview)
                    Button("Zoom out") { zoom.step(-1) }.disabled(session.showsOverview)
                    Button("Fit page") { zoom.fit(width: false) }.disabled(session.showsOverview)
                    Button("Fit width") { zoom.fit(width: true) }.disabled(session.showsOverview)
                } label: { SymbolIcon(systemName: "ellipsis").frame(width: RemileControl.toolHit, height: RemileControl.toolHit) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("View options")
            } else { ReaderZoomControls(zoom: zoom).disabled(session.showsOverview) }
            Button { session.sidebar = .search; session.showsSidebar = true; searchFocused = true } label: { SymbolIcon(systemName: "magnifyingglass") }.remileHelp("Find in document").keyboardShortcut("f")
        }.buttonStyle(RemileToolStyle()).font(RemileType.control).labelStyle(.titleAndIcon)
    }
    private func controlLabel(_ title: String, symbol: String, compact: Bool) -> some View {
        SymbolIcon(systemName: symbol).accessibilityLabel(title)
    }

    private var selectionActions: PDFSelectionActions {
        PDFSelectionActions(highlight: { context, color in
            guard context.document === session.document, session.select(context.selection) else { return }; session.highlightSelection(color: color)
        }, addNote: { context in
            guard context.document === session.document, session.select(context.selection) else { return }; session.beginComment()
        }, ask: { context in
            guard context.document === session.document else { return }
            assistant.cancel(); presentation.selectedPassages = context.passages(path: assistantPath)
            if assistant.question.isEmpty { assistant.question = "Explain the selected passage." }
            withAnimation(reduceMotion ? nil : RemileMotion.panel) { presentation.ask = true }
        }, translate: { context in
            guard context.document === session.document else { return }; presentation.translation = SelectionTranslation(text: context.text)
        }, removeHighlight: { document, annotation in
            guard document === session.document else { return }; session.deleteHighlight(annotation)
        }, removeNote: { document, annotation in
            guard document === session.document else { return }; session.deleteNote(annotation)
        })
    }

    private var editingStrip: some View {
        GeometryReader { geometry in
            editingControlRow(compact: geometry.size.width < 800)
        }.frame(height: 32).padding(.horizontal, 16).padding(.vertical, 6)
    }
    private func editingControlRow(compact: Bool) -> some View {
        HStack(spacing: RemileControl.spacing) {
            if !compact { Text(session.showsOverview ? "Pages" : "Edit PDF").font(RemileType.section) }
            Button { session.choosePDFs() } label: { SymbolIcon(systemName: "doc.badge.plus") }
                .disabled(!session.canArrangePages).remileHelp("Add PDFs").accessibilityLabel("Add PDFs")
            PDFPageSizeControl(session: session, compact: true).disabled(!session.canArrangePages)
            if !session.showsOverview {
            Button { session.beginComment() } label: { controlLabel("Note", symbol: "text.bubble", compact: compact) }
                .disabled(session.document?.allowsCommenting != true).remileHelp("Add a note at the selection or current page")
            Button { session.highlightSelection() } label: { controlLabel("Highlight", symbol: "highlighter", compact: compact) }
                .disabled(!session.canHighlight).remileHelp("Highlight selected text")
            Menu {
                Button("Select Text") { session.drawingTool = nil }
                ForEach(PDFDrawingTool.allCases) { tool in
                    Button { session.drawingTool = tool } label: { SymbolLabel(tool.rawValue, systemImage: tool.symbol) }
                }
                Divider()
                ForEach(HighlightColor.allCases) { color in
                    Button { session.drawingColor = color } label: {
                        if session.drawingColor == color { SymbolLabel(color.name, systemImage: "checkmark") } else { Text(color.name) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    SymbolIcon(systemName: session.drawingTool?.symbol ?? "pencil.line")
                        .font(RemileType.control).frame(width: 20, height: 28)

                    SymbolIcon(systemName: "chevron.down")
                }.foregroundStyle(session.drawingTool != nil ? RemileStyle.accent : RemileStyle.ink).contentShape(Rectangle())
                    .accessibilityElement(children: .ignore).accessibilityLabel("Draw or add shapes")
            }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().frame(minWidth: RemileControl.toolHit, minHeight: RemileControl.toolHit)
                .accessibilityLabel("Draw or add shapes").accessibilityValue(session.drawingTool?.rawValue ?? "Select Text")
                .remileHelp("Draw or add shapes. Escape returns to text selection.")
            }
            Divider().frame(height: 20)
            Button { session.rotateVisiblePages(clockwise: false) } label: { SymbolIcon(systemName: "rotate.left").frame(width: RemileControl.toolHit, height: RemileControl.toolHit).contentShape(Rectangle()) }
                .buttonStyle(RemileCompactToolStyle())
                .disabled(!session.canArrangePages).remileHelp(session.showsOverview ? "Rotate selected pages left" : "Rotate current page left")
            Button { session.rotateVisiblePages(clockwise: true) } label: { SymbolIcon(systemName: "rotate.right").frame(width: RemileControl.toolHit, height: RemileControl.toolHit).contentShape(Rectangle()) }
                .buttonStyle(RemileCompactToolStyle())
                .disabled(!session.canArrangePages).remileHelp(session.showsOverview ? "Rotate selected pages right" : "Rotate current page right")
            Spacer(minLength: 12)
        }
        .buttonStyle(RemileCompactToolStyle())
    }

    private var assistantPath: String { fileURL?.path ?? presentation.untitledPath }
    private func toggleAssistant() {
        if presentation.ask { assistant.cancel() }
        withAnimation(reduceMotion ? nil : RemileMotion.panel) { presentation.ask.toggle() }
    }

    private func revealLibraryPage() {
        guard let request = navigation.request, let fileURL,
              fileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: request.path).resolvingSymlinksInPath().path else { return }
        session.revealLibraryPage(request.page, terms: request.terms, excerpt: request.noteExcerpt, addNote: request.noteExcerpt != nil)
        navigation.request = nil
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(PDFSession.Sidebar.allCases, id: \.self) { tab in
                    Button { withAnimation(reduceMotion ? nil : RemileMotion.panel) { session.sidebar = tab } } label: {
                        SymbolIcon(systemName: sidebarSymbol(tab)).frame(width: 20, height: 20).frame(maxWidth: .infinity).frame(height: 32)
                            .foregroundStyle(session.sidebar == tab ? RemileStyle.accent : RemileStyle.ink.opacity(0.7))
                            .overlay(alignment: .topTrailing) {
                                if tab == .comments && !session.comments.isEmpty { Circle().fill(RemileStyle.accent).frame(width: 6, height: 6).padding(4).accessibilityLabel("\(session.comments.count) comments") }
                            }
                            .background(session.sidebar == tab ? RemileStyle.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).remileHelp(tab.rawValue).accessibilityLabel("Show " + tab.rawValue).accessibilityValue(session.sidebar == tab ? "Selected" : "")
                }
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            HStack {
                Text(session.sidebar.rawValue).font(RemileType.heading)
                Spacer(minLength: 0)
                if session.sidebar == .comments { PDFCommentExportMenu(session: session, name: fileURL?.lastPathComponent ?? "Untitled.pdf") }
            }.frame(height: 32).padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            switch session.sidebar {
            case .pages: if let document = session.document { PDFPagesPanel(document: document, currentPage: session.currentPage, select: session.goToPage) }
            case .outline: if let document = session.document { PDFOutlinePanel(document: document, select: session.goToOutline) }
            case .search: searchPanel
            case .comments: commentsPanel
            case .highlights: highlightsPanel
            }
        }.frame(maxHeight: .infinity, alignment: .top).background(RemileStyle.sidebar)
    }
    private func sidebarSymbol(_ tab: PDFSession.Sidebar) -> String {
        switch tab {
        case .pages: return "doc.on.doc"
        case .outline: return "list.bullet.indent"
        case .search: return "magnifyingglass"
        case .comments: return "text.bubble"
        case .highlights: return "highlighter"
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Find in this PDF", text: $session.query).textFieldStyle(.roundedBorder)
                .focused($searchFocused).onAppear { searchFocused = true }
            Toggle("Match case", isOn: $session.caseSensitive).toggleStyle(.checkbox)
            if session.searching { ProgressView("Searching…").controlSize(.small) }
            Text(session.resultLimitReached ? "First 500 matches · refine your search" : "\(session.matches.count) matches").font(RemileType.caption).foregroundStyle(.secondary)
            if !session.query.isEmpty && !session.searching && session.matches.isEmpty {
                Text("No matching text. Scanned pages may need OCR.").font(RemileType.callout).foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(Set(session.matches.map(\.page))).sorted(), id: \.self) { page in
                    Section("Page \(page) · \(session.matches.filter { $0.page == page }.count)") {
                        ForEach(session.matches.filter { $0.page == page }) { match in
                            Button { session.reveal(match) } label: {
                                Text(SearchExcerpt.highlight(match.text, query: session.query, caseSensitive: session.caseSensitive)).lineLimit(4).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }.padding(.horizontal, 16).padding(.top, 10)
    }

    private var highlightsPanel: some View {
        Group {
            if session.highlights.isEmpty { ContentUnavailableView("No highlights", systemImage: "highlighter").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                List(session.highlights) { mark in
                    Button { session.reveal(mark) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: mark.annotation.color).opacity(1)).frame(width: 5)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Page \(mark.pageNumber)").font(RemileType.caption).foregroundStyle(.secondary)
                                Text(mark.text).lineLimit(4).multilineTextAlignment(.leading)
                            }
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .contextMenu { Button("Delete Highlight", role: .destructive) { session.deleteAnnotation(mark) } }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.onAppear { session.loadComments() }
    }

    private var commentsPanel: some View {
        VStack(spacing: 0) {
            commentList
            if let context = session.draftContext {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.isEditingNote ? "Edit note" : session.isReplyDraft ? "Reply" : "New note").font(RemileType.heading)
                    Text(context).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(3)
                    TextField("Author (optional)", text: $session.author).textFieldStyle(.roundedBorder)
                    TextEditor(text: $session.draft).frame(height: 90).border(.secondary.opacity(0.2))
                        .accessibilityLabel(session.isEditingNote ? "Edit note" : "New note")
                    HStack {
                        Button("Cancel") { session.cancelComment() }
                        Spacer()
                        Button(session.isEditingNote ? "Save note" : session.isReplyDraft ? "Add reply" : "Add note") { session.saveComment() }.buttonStyle(.borderedProminent)
                            .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(12)
            }
        }
    }

    private var commentList: some View {
        Group {
            if session.loadingComments && session.comments.isEmpty {
                ProgressView("Loading notes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.comments.isEmpty {
                ContentUnavailableView("No notes", systemImage: "text.bubble").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(session.threads) { thread in
                                VStack(alignment: .leading, spacing: 0) {
                                    commentCard(thread.root)
                                    ForEach(Array(thread.replies.enumerated()), id: \.element.id) { index, reply in
                                        commentCard(reply).padding(.leading, 24).padding(.bottom, 10)
                                            .background(alignment: .leading) {
                                                NoteReplyBranch(last: index == thread.replies.count - 1)
                                                    .stroke(RemileStyle.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                                                    .frame(width: 24).accessibilityHidden(true)
                                            }.padding(.leading, 12)
                                    }
                                }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }.padding(12)
                    }
                    .onChange(of: session.selectedComment) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }.onAppear { session.loadComments() }
    }
    private func commentCard(_ comment: PDFSession.Comment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(comment.author).font(RemileType.caption.bold())
                Spacer()
                Button("p. \(comment.pageNumber)") { session.reveal(comment) }
                    .buttonStyle(.plain).font(RemileType.caption).foregroundStyle(.secondary)
                    .remileHelp("Show comment on the page")
            }
            if let parent = comment.parent, let original = session.comments.first(where: { $0.id == parent }) {
                SymbolLabel("Reply to \(original.author)", systemImage: "arrow.turn.up.left").font(RemileType.small).foregroundStyle(RemileStyle.accent)
                Text(original.text).font(RemileType.small).foregroundStyle(.secondary).lineLimit(1).help(original.text)
            }
            Text(comment.text).textSelection(.enabled).multilineTextAlignment(.leading)
            HStack {
                if let date = comment.annotation.modificationDate {
                    Text(date, style: .date).font(RemileType.small).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { session.beginEditingNote(comment.annotation) }.buttonStyle(.borderless).font(RemileType.caption)
                    .disabled(session.document?.allowsCommenting != true || session.document?.isEncrypted == true)
                Button("Reply") { session.beginReply(comment) }.buttonStyle(.borderless).font(RemileType.caption)
                    .disabled(session.document?.allowsCommenting != true || session.document?.isEncrypted == true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(session.selectedComment == comment.id ? RemileStyle.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu { Button(comment.parent == nil && session.threads.contains(where: { $0.root.id == comment.id && !$0.replies.isEmpty }) ? "Delete Thread" : "Delete Note", role: .destructive) { session.deleteAnnotation(comment) } }
        .id(comment.id)
    }

}

private struct NoteReplyBranch: Shape {
    let last: Bool
    func path(in rect: CGRect) -> Path {
        let joint = min(20, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: 6, y: 0))
        path.addLine(to: CGPoint(x: 6, y: max(0, joint - 8)))
        path.addQuadCurve(to: CGPoint(x: 14, y: joint), control: CGPoint(x: 6, y: joint))
        path.addLine(to: CGPoint(x: rect.maxX, y: joint))
        if !last {
            path.move(to: CGPoint(x: 6, y: max(0, joint - 8)))
            path.addLine(to: CGPoint(x: 6, y: rect.maxY))
        }
        return path
    }
}
