import SwiftUI
import PDFKit

struct PDFWorkspace: View {
    let data: Data
    var fileURL: URL? = nil
    @ObservedObject private var navigation = ReaderNavigation.shared
    let updateDocument: (Data) -> Void
    @StateObject private var session = PDFSession()
    @StateObject private var assistant = DocumentAssistant()
    @StateObject private var presentation = Presentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let assistantContext = PDFAssistantContext()
    private final class Presentation: ObservableObject {
        @Published var ask = false
        let untitledPath = "/deerstalker-untitled-" + UUID().uuidString + "/Untitled.pdf"
    }
    @Environment(\.undoManager) private var undoManager
    @FocusState private var searchFocused: Bool
    @StateObject private var zoom = ReaderZoom()

    var body: some View {
        HSplitView {
            if session.showsSidebar {
                sidebar.frame(minWidth: 230, idealWidth: 280, maxWidth: 380)
            }
            Group {
                if let document = session.document, !document.isLocked {
                    PDFReader(session: session, zoom: zoom)
                } else if session.document?.isLocked == true {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.doc").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Unlock this PDF").font(.title2)
                        SecureField("Password", text: $session.password)
                            .textFieldStyle(.roundedBorder).frame(width: 260).onSubmit { session.unlock() }
                        if let error = session.passwordError { Text(error).foregroundStyle(.red).font(.callout) }
                        Button("Unlock") { session.unlock() }.buttonStyle(.borderedProminent).disabled(session.password.isEmpty)
                    }
                } else {
                    ContentUnavailableView("Unable to open PDF", systemImage: "doc.badge.exclamationmark", description: Text("The document may be damaged or unsupported."))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if presentation.ask {
                AssistantPanel(assistant: assistant, passages: [], topic: fileURL?.deletingPathExtension().lastPathComponent ?? "this PDF", select: { source in
                    let location = source.location
                    guard location.path == assistantPath else { return }
                    session.revealLibraryPage(location.unit, terms: [], excerpt: source.text)
                }, close: { toggleAssistant() }, retrieve: { question in
                    guard session.document?.allowsCopying == true, session.document?.isLocked == false else { throw PDFAssistantContext.Failure.restricted }
                    return try await assistantContext.passages(data: session.committedData ?? data, password: session.assistantPassword, path: assistantPath, question: question,
                        currentPage: session.currentPage, selection: session.assistantSelection) { fraction in
                            await assistant.reportProgress(fraction)
                        }
                }).transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = session.citationStatus {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { session.dismissCitationStatus() }
                }.padding(10).background(.bar)
            }
        }
        .onAppear { assistant.useHistory(fileURL.map { "pdf:" + $0.path }); session.undoManager = undoManager; session.load(data); revealLibraryPage(); if !session.query.isEmpty { session.search() } }
        .onChange(of: data) { _, data in assistant.cancel(); session.load(data) }
        .onChange(of: fileURL) { assistant.useHistory(fileURL.map { "pdf:" + $0.path }) }
        .onChange(of: navigation.request?.id) { revealLibraryPage() }
        .onDisappear { assistant.cancel(); session.stop() }
        .onChange(of: session.query) { session.search() }
        .onChange(of: session.caseSensitive) { session.search() }
        .onChange(of: session.committedData) { _, bytes in if let bytes { assistant.cancel(); updateDocument(bytes) } }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { session.showsSidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help("Show search and comments")
                Button { session.previousPage() } label: { Image(systemName: "chevron.up") }.help("Previous page").disabled(session.currentPage <= 1)
                Button { session.nextPage() } label: { Image(systemName: "chevron.down") }.help("Next page").disabled(session.currentPage >= (session.document?.pageCount ?? 0))
                Text("\(session.currentPage) / \(session.document?.pageCount ?? 0)").monospacedDigit().foregroundStyle(.secondary).fixedSize().padding(.horizontal, 8).frame(minWidth: 64)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { toggleAssistant() } label: { Label("Ask", systemImage: "sparkles") }
                    .help("Ask about this PDF").disabled(session.document?.allowsCopying != true || session.document?.isLocked != false)
                Button { session.beginComment() } label: { Image(systemName: "text.bubble") }
                    .help("Add a note at the selection or current page")
                    .disabled(session.document == nil || session.document?.isLocked == true || session.document?.allowsCommenting == false || session.document?.isEncrypted == true)
                ReaderZoomControls(zoom: zoom)
                Button {
                    session.sidebar = .search
                    session.showsSidebar = true
                    searchFocused = true
                } label: { Image(systemName: "magnifyingglass") }.help("Find in document").keyboardShortcut("f")
            }
        }
    }

    private var assistantPath: String { fileURL?.path ?? presentation.untitledPath }
    private func toggleAssistant() {
        if presentation.ask { assistant.cancel() }
        withAnimation(reduceMotion ? nil : DeerMotion.panel) { presentation.ask.toggle() }
    }

    private func revealLibraryPage() {
        guard let request = navigation.request, let fileURL,
              fileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: request.path).resolvingSymlinksInPath().path else { return }
        session.revealLibraryPage(request.page, terms: request.terms)
        navigation.request = nil
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $session.sidebar) {
                ForEach(PDFSession.Sidebar.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(12)
            if session.sidebar == .search { searchPanel } else { commentsPanel }
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Find in this PDF", text: $session.query).textFieldStyle(.roundedBorder)
                .focused($searchFocused).onAppear { searchFocused = true }
            Toggle("Match case", isOn: $session.caseSensitive).toggleStyle(.checkbox)
            if session.searching { ProgressView("Searching…").controlSize(.small) }
            Text(session.resultLimitReached ? "First 500 matches · refine your search" : "\(session.matches.count) matches").font(.caption).foregroundStyle(.secondary)
            if !session.query.isEmpty && !session.searching && session.matches.isEmpty {
                Text("No matching text. Scanned pages may need OCR.").font(.callout).foregroundStyle(.secondary)
            }
            List(session.matches) { match in
                Button { session.reveal(match) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Page \(match.page)").font(.caption).foregroundStyle(.secondary)
                        Text(match.text).lineLimit(3).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.listStyle(.sidebar)
        }.padding(.horizontal, 12)
    }

    private var commentsPanel: some View {
        VStack(spacing: 0) {
            commentList
            if let context = session.draftContext {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.isReplyDraft ? "Reply" : "New note").font(.headline)
                    Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    TextField("Author (optional)", text: $session.author).textFieldStyle(.roundedBorder)
                    TextEditor(text: $session.draft).frame(height: 90).border(.secondary.opacity(0.2))
                        .accessibilityLabel("New comment")
                    if let error = session.editingError { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button("Cancel") { session.cancelComment() }
                        Spacer()
                        Button(session.isReplyDraft ? "Add reply" : "Add note") { session.saveComment() }.buttonStyle(.borderedProminent)
                            .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(12)
            } else if let error = session.editingError {
                Text(error).font(.caption).foregroundStyle(.red).padding(12)
            }
        }
    }

    private var commentList: some View {
        Group {
            if session.loadingComments && session.comments.isEmpty {
                ProgressView("Loading comments…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.comments.isEmpty {
                ContentUnavailableView("No comments", systemImage: "text.bubble", description: Text("Comments saved in this PDF will appear here."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(session.threads) { thread in
                                VStack(alignment: .leading, spacing: 10) {
                                    commentCard(thread.root)
                                    ForEach(thread.replies) { reply in
                                        commentCard(reply).padding(.leading, 16)
                                    }
                                }
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
                Text(comment.author).font(.caption.bold())
                Spacer()
                Button("p. \(comment.pageNumber)") { session.reveal(comment) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .help("Show comment on the page")
            }
            Text(comment.text).textSelection(.enabled).multilineTextAlignment(.leading)
            HStack {
                if let date = comment.annotation.modificationDate {
                    Text(date, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reply") { session.beginReply(comment) }.buttonStyle(.borderless).font(.caption)
                    .disabled(session.document?.allowsCommenting != true || session.document?.isEncrypted == true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(session.selectedComment == comment.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .id(comment.id)
    }

}
