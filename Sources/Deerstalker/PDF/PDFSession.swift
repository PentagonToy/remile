import PDFKit
import Combine

final class PDFSession: NSObject, ObservableObject {
    struct Match: Identifiable {
        let id = UUID()
        let selection: PDFSelection
        let page: Int
        let text: String
    }
    struct Comment: Identifiable {
        let id: ObjectIdentifier
        let annotation: PDFAnnotation
        let page: PDFPage
        let pageNumber: Int
        let author: String
        let text: String
        let parent: ObjectIdentifier?
    }
    enum Sidebar: String, CaseIterable { case search = "Search", comments = "Comments" }

    struct Thread: Identifiable {
        let root: Comment
        var replies: [Comment]
        var id: ObjectIdentifier { root.id }
    }
    var threads: [Thread] {
        let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [ObjectIdentifier: [Comment]] = [:]
        for comment in comments {
            var root = comment
            var visited: Set<ObjectIdentifier> = [root.id]
            while let parent = root.parent, let ancestor = byID[parent], visited.insert(parent).inserted { root = ancestor }
            groups[root.id, default: []].append(comment)
        }
        return comments.compactMap { root in
            guard let members = groups[root.id] else { return nil }
            return Thread(root: root, replies: members.filter { $0.id != root.id })
        }
    }

    @Published var query = ""
    @Published var caseSensitive = false
    @Published var sidebar: Sidebar = .search
    @Published var showsSidebar = false
    @Published private(set) var document: PDFDocument?
    @Published private(set) var matches: [Match] = []
    @Published private(set) var searching = false
    @Published private(set) var resultLimitReached = false
    @Published private(set) var currentPage = 0
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var loadingComments = false
    @Published var selectedComment: ObjectIdentifier?
    @Published var password = ""
    private(set) var assistantPassword = ""
    @Published private(set) var passwordError: String?
    @Published var draft = ""
    @Published var author = ""
    @Published private(set) var draftContext: String?
    @Published private(set) var editingError: String?
    @Published private(set) var activeCitation: AssistantCitation?
    @Published private(set) var citationStatus: String?
    @Published private(set) var committedData: Data?
    weak var undoManager: UndoManager?
    private var draftPage: PDFPage?
    private var draftParent: PDFAnnotation?
    private var commentGraph: PDFCommentGraph?
    var isReplyDraft: Bool { draftParent != nil }
    private var draftBounds = CGRect.zero
    private weak var view: PDFView?
    private var libraryDestination: (page: Int, terms: [String], excerpt: String?)?
    private var inputData: Data?
    private var observers: [NSObjectProtocol] = []
    private var searchWork: DispatchWorkItem?
    private var commentTask: Task<Void, Never>?
    private var generation = UUID()
    private var commentGeneration = UUID()
    private var commentsLoaded = false
    private var searchDelegate: SearchDelegate?

    func load(_ data: Data) {
        guard inputData != data else { return }
        stop()
        undoManager?.removeAllActions(withTarget: self)
        inputData = data
        libraryDestination = nil
        document = PDFDocument(data: data)
        currentPage = (document?.pageCount ?? 0) > 0 ? 1 : 0
        matches = []
        citationStatus = nil; activeCitation = nil
        comments = []
        commentsLoaded = false
        selectedComment = nil
        password = ""
        assistantPassword = ""
        passwordError = nil
        cancelComment()
        committedData = nil
        commentGraph = nil
    }

    func attach(_ view: PDFView) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.view = view
        applyLibraryDestination()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
            guard let self, let view, let page = view.currentPage, let document = self.document,
                  view.document === document, page.document === document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            self.currentPage = index + 1
        })
        observers.append(center.addObserver(forName: .PDFViewAnnotationHit, object: view, queue: .main) { [weak self] notification in
            guard let self, let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
                  annotation.contents?.isEmpty == false else { return }
            self.selectedComment = ObjectIdentifier(annotation)
            self.sidebar = .comments
            self.showsSidebar = true
            self.loadComments()
        })
    }

    func revealLibraryPage(_ number: Int, terms: [String], excerpt: String? = nil) {
        guard number > 0 else { return }
        libraryDestination = (number, terms, excerpt)
        applyLibraryDestination()
    }

    func applyLibraryDestination() {
        guard let target = libraryDestination, let view, let document, view.document === document,
              let page = document.page(at: target.page - 1) else { return }
        libraryDestination = nil
        view.go(to: page)
        currentPage = target.page
        citationStatus = nil
        activeCitation = target.excerpt.map { AssistantCitation(location: AssistantLocation(path: "", unit: target.page, label: "Page \(target.page)"), text: $0) }
        var highlights: [PDFSelection] = []
        if let excerpt = target.excerpt {
            highlights = PDFCitation.selections(on: page, excerpt: excerpt)
            if highlights.isEmpty { citationStatus = "Passage not found on this page." }
        }
        let text = (page.string ?? "") as NSString
        for term in target.terms where target.excerpt == nil && !term.isEmpty {
            var range = NSRange(location: 0, length: text.length)
            while range.length > 0, highlights.count < 200 {
                let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                guard found.location != NSNotFound else { break }
                if let selection = page.selection(for: found) { selection.color = NSColor.systemYellow.withAlphaComponent(0.4); highlights.append(selection) }
                range = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            }
        }
        view.highlightedSelections = highlights
        if let first = highlights.first { view.go(to: first) }
    }
    func dismissCitationStatus() { citationStatus = nil }

    func search() {
        generation = UUID()
        searchWork?.cancel()
        document?.delegate = nil
        document?.cancelFindString()
        searchDelegate = nil
        matches = []
        resultLimitReached = false
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searching = !text.isEmpty && document != nil && document?.isLocked == false
        guard searching else { return }
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, let document = self.document else { return }
            let delegate = SearchDelegate()
            delegate.match = { [weak self, weak document] selection in
                guard let self, let document, self.generation == token, let page = selection.pages.first else { return }
                guard self.matches.count < 500 else {
                    self.resultLimitReached = true
                    document.cancelFindString()
                    self.searching = false
                    return
                }
                let context = selection.copy() as? PDFSelection
                context?.extendForLineBoundaries()
                self.matches.append(Match(selection: selection, page: document.index(for: page) + 1, text: context?.string ?? selection.string ?? text))
            }
            delegate.finished = { [weak self] in
                guard self?.generation == token else { return }
                self?.searching = false
            }
            self.searchDelegate = delegate
            document.delegate = delegate
            document.beginFindString(text, withOptions: self.caseSensitive ? [] : .caseInsensitive)
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func reveal(_ match: Match) {
        view?.setCurrentSelection(match.selection, animate: true)
        view?.go(to: match.selection)
    }
    func reveal(_ comment: Comment) {
        selectedComment = comment.id
        view?.go(to: comment.annotation.bounds.insetBy(dx: -24, dy: -24), on: comment.page)
    }

    func loadComments() {
        guard !commentsLoaded, commentTask == nil, let document, !document.isLocked else { return }
        let token = commentGeneration
        loadingComments = true
        comments = []
        commentTask = Task { @MainActor [weak self, weak document] in
            guard let self, let document else { return }
            if self.commentGraph == nil { self.commentGraph = PDFCommentGraph(document: document) }
            defer {
                if self.commentGeneration == token {
                    self.loadingComments = false
                    self.commentTask = nil
                }
            }
            for index in 0..<document.pageCount {
                guard !Task.isCancelled, self.commentGeneration == token else { return }
                if let page = document.page(at: index) {
                    for annotation in page.annotations where annotation.type != "Popup" && annotation.type != "Widget" {
                        guard let text = annotation.contents, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        self.comments.append(Comment(id: ObjectIdentifier(annotation), annotation: annotation, page: page,
                                                     pageNumber: index + 1, author: annotation.userName ?? "Unknown author", text: text,
                                                     parent: self.commentGraph?.parent(of: annotation)))
                    }
                }
                await Task.yield()
            }
            guard !Task.isCancelled, self.commentGeneration == token else { return }
            self.commentsLoaded = true
        }
    }

    func beginComment() {
        // A second click must not discard an unfinished draft or move its anchor.
        guard draftPage == nil, let document, !document.isLocked,
              let page = view?.currentSelection?.pages.first ?? view?.currentPage else { return }
        let crop = page.bounds(for: .cropBox)
        let selection = view?.currentSelection
        let anchor = selection?.bounds(for: page) ?? CGRect(x: crop.midX, y: crop.midY, width: 24, height: 24)
        draftBounds = CGRect(x: max(crop.minX, min(anchor.maxX, crop.maxX - 24)),
                             y: max(crop.minY, min(anchor.maxY - 24, crop.maxY - 24)), width: 24, height: 24)
        draftPage = page
        draftContext = selection?.string?.isEmpty == false ? selection?.string : "Page \(document.index(for: page) + 1)"
        editingError = nil
        sidebar = .comments
        showsSidebar = true
    }

    func cancelComment() {
        draft = ""
        draftContext = nil
        draftPage = nil
        draftParent = nil
        editingError = nil
    }

    func saveComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let page = draftPage else { return }
        let note = PDFNotes.make(text: text, author: author, bounds: draftBounds)
        if applyNote(note, page: page, adding: true, parent: draftParent) {
            selectedComment = ObjectIdentifier(note)
            cancelComment()
        }
    }

    func beginReply(_ comment: Comment) {
        guard draftPage == nil else {
            editingError = "Finish or cancel the current draft before starting another reply."
            sidebar = .comments
            showsSidebar = true
            return
        }
        draftPage = comment.page
        draftBounds = comment.annotation.bounds
        draftParent = comment.annotation
        draftContext = "\(comment.author): \(comment.text)"
        editingError = nil
        sidebar = .comments
        showsSidebar = true
        reveal(comment)
    }

    @discardableResult
    private func applyNote(_ note: PDFAnnotation, page: PDFPage, adding: Bool, parent: PDFAnnotation? = nil) -> Bool {
        guard let document, page.document === document else { return false }
        do {
            let graph = commentGraph ?? PDFCommentGraph(document: document)
            commentGraph = graph
            let bytes = try PDFNotes.apply(note, on: page, in: document, adding: adding, graph: graph, parent: parent)
            // Accept our own writeback without reloading the PDF and losing reading state.
            inputData = bytes
            committedData = bytes
            editingError = nil
            undoManager?.registerUndo(withTarget: self) { target in
                target.applyNote(note, page: page, adding: !adding, parent: parent)
            }
            undoManager?.setActionName(parent == nil ? "Add Comment" : "Reply to Comment")
            commentGeneration = UUID()
            commentTask?.cancel()
            commentTask = nil
            commentsLoaded = false
            loadComments()
            view?.needsDisplay = true
            return true
        } catch {
            editingError = error.localizedDescription
            return false
        }
    }

    var assistantSelection: (page: Int, text: String)? {
        guard let document, document.allowsCopying, !document.isLocked, view?.document === document,
              let selection = view?.currentSelection, let page = selection.pages.first,
              page.document === document, let text = selection.string, !text.isEmpty else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        // A multi-page selection must not be attributed wholly to its first page.
        let selected = selection.pages.count == 1 ? text : selection.selectionsByLine()
            .filter { $0.pages.first === page }.compactMap(\.string).joined(separator: " ")
        return (index + 1, String(selected.prefix(3000)))
    }

    func previousPage() { view?.goToPreviousPage(nil) }
    func nextPage() { view?.goToNextPage(nil) }
    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func fitPage() { view?.autoScales = true }
    func unlock() {
        guard let document else { return }
        let candidate = password
        password = ""
        if document.unlock(withPassword: candidate) {
            assistantPassword = candidate
            passwordError = nil
            currentPage = document.pageCount > 0 ? 1 : 0
            objectWillChange.send()
        } else {
            passwordError = "That password did not unlock this PDF."
        }
    }
    func stop() {
        generation = UUID()
        searchWork?.cancel()
        document?.delegate = nil
        document?.cancelFindString()
        commentGeneration = UUID()
        commentTask?.cancel()
        commentTask = nil
        loadingComments = false
        searching = false
    }
    deinit {
        searchWork?.cancel()
        commentTask?.cancel()
        document?.cancelFindString()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

private final class SearchDelegate: NSObject, PDFDocumentDelegate {
    var match: ((PDFSelection) -> Void)?
    var finished: (() -> Void)?
    func didMatchString(_ instance: PDFSelection) { match?(instance) }
    func documentDidEndDocumentFind(_ notification: Notification) { finished?() }
}
