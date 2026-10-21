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
    enum Sidebar: String, CaseIterable { case pages = "Pages", outline = "Outline", search = "Search", comments = "Comments", highlights = "Highlights" }
    /// Link Contents are accessibility descriptions, not a review conversation.
    static func isReviewComment(_ annotation: PDFAnnotation) -> Bool {
        PDFCommentExport.isReviewComment(annotation)
    }

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
    @Published var sidebar: Sidebar = .pages
    @Published var showsSidebar = false
    @Published var twoPage = false
    @Published var firstPageAlone = false
    @Published var isEditing = false
    let protection = PDFEditProtection()
    @Published var drawingTool: PDFDrawingTool?
    @Published var drawingColor: HighlightColor = .vermilion
    @Published var showsOverview = false
    @Published var selectedOverviewPages: Set<ObjectIdentifier> = []
    @Published private(set) var pageRevision = UUID()
    @Published private(set) var document: PDFDocument?
    @Published private(set) var matches: [Match] = []
    @Published private(set) var searching = false
    @Published private(set) var resultLimitReached = false
    @Published private(set) var currentPage = 0
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var highlights: [Comment] = []
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
    @Published private(set) var pendingAnnotationRevision = UUID()
    @Published private(set) var hasPendingAnnotations = false
    @Published private(set) var committedData: Data?
    weak var undoManager: UndoManager?
    private var draftPage: PDFPage?
    private var draftParent: PDFAnnotation?
    private var commentGraph: PDFCommentGraph?
    var isReplyDraft: Bool { draftParent != nil }
    private var draftBounds = CGRect.zero
    private weak var view: PDFView?
    private var libraryDestination: (page: Int, terms: [String], excerpt: String?, note: Bool)?
    private var inputData: Data?
    private var openedWithSignature = false
    func allowDrawingGesture() -> Bool { isEditing && allowProtectedEdit() }
    func requestEditingUnlock() {
        guard let inputData else { return }
        protection.requestUnlock(data: inputData)
        objectWillChange.send()
    }
    @discardableResult private func allowProtectedEdit() -> Bool {
        guard let inputData else { return false }
        do { return try protection.allowEdit(data: inputData) }
        catch { editingError = error.localizedDescription; return false }
    }
    func signatureSaveStatus(for bytes: Data) -> PDFSignatureSaveStatus {
        guard openedWithSignature else { return .unsigned }
        return commentGraph?.signaturePreservedData == bytes ? .preserved : .atRisk
    }
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
        openedWithSignature = document.map(PDFEditing.hasDigitalSignature) ?? false
        protection.configure(document)
        pageRevision = UUID(); showsOverview = false
        selectedOverviewPages = Set(document?.page(at: 0).map { [ObjectIdentifier($0)] } ?? [])
        currentPage = (document?.pageCount ?? 0) > 0 ? 1 : 0
        matches = []
        citationStatus = nil; activeCitation = nil
        comments = []; highlights = []
        commentsLoaded = false
        selectedComment = nil
        password = ""
        assistantPassword = ""
        passwordError = nil
        cancelComment()
        committedData = nil; hasPendingAnnotations = false
        commentGraph = nil
        isEditing = false; drawingTool = nil
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
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in self?.objectWillChange.send() })
        observers.append(center.addObserver(forName: .PDFViewAnnotationHit, object: view, queue: .main) { [weak self] notification in
            guard let self, let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
                  Self.isReviewComment(annotation) else { return }
            self.selectedComment = ObjectIdentifier(annotation)
            self.sidebar = .comments
            self.showsSidebar = true
            self.loadComments()
        })
    }

    func revealLibraryPage(_ number: Int, terms: [String], excerpt: String? = nil, addNote: Bool = false) {
        guard number > 0 else { return }
        libraryDestination = (number, terms, excerpt, addNote)
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
        if target.note { if let first = highlights.first { view.setCurrentSelection(first, animate: false) }; beginComment() }
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

    func exportComments(name: String) throws -> PDFCommentExport.Archive {
        guard let document else { throw CocoaError(.fileReadUnknown) }
        return try PDFCommentExport.capture(document, name: name, graph: commentGraph)
    }
    func loadComments() {
        guard !commentsLoaded, commentTask == nil, let document, !document.isLocked else { return }
        let token = commentGeneration
        loadingComments = true
        comments = []; highlights = []
        commentTask = Task { @MainActor [weak self, weak document] in
            guard let self, let document else { return }
            if self.commentGraph == nil { self.commentGraph = PDFCommentGraph(document: document, sourceData: self.inputData, allowSignatureChanges: true) }
            defer {
                if self.commentGeneration == token {
                    self.loadingComments = false
                    self.commentTask = nil
                }
            }
            for index in 0..<document.pageCount {
                guard !Task.isCancelled, self.commentGeneration == token else { return }
                if let page = document.page(at: index) {
                    for annotation in page.annotations {
                        if ["Highlight", "Underline", "Squiggly", "StrikeOut"].contains(annotation.type ?? "") {
                            let excerpt = annotation.contents?.isEmpty == false ? annotation.contents! : page.selection(for: annotation.bounds)?.string ?? "Highlighted text"
                            self.highlights.append(Comment(id: ObjectIdentifier(annotation), annotation: annotation, page: page, pageNumber: index + 1, author: annotation.userName ?? "", text: excerpt, parent: nil))
                        }
                        guard Self.isReviewComment(annotation) else { continue }
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
        guard allowProtectedEdit() else { return }
        // A second click must not discard an unfinished draft or move its anchor.
        guard draftPage == nil, let document, !document.isLocked, view?.document === document,
              let page = view?.currentSelection?.pages.first ?? view?.currentPage, page.document === document else { return }
        do { try PDFEditing.validate(document, annotationsOnly: true) } catch { editingError = error.localizedDescription; return }
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
        guard allowProtectedEdit() else { return }
        guard let document, comment.page.document === document, comment.annotation.page === comment.page else { return }
        do { try PDFEditing.validate(document, annotationsOnly: true) } catch { editingError = error.localizedDescription; return }
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
        guard allowProtectedEdit(), let document, page.document === document else { return false }
        do {
            try PDFEditing.validate(document, annotationsOnly: true)
            let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true)
            commentGraph = graph
            try PDFNotes.change([(note, page, parent)], in: document, adding: adding, graph: graph)
            acceptPendingAnnotation()
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

    var canEdit: Bool {
        guard let document else { return false }
        return !document.isLocked && !document.isEncrypted && (document.allowsCommenting || document.allowsDocumentAssembly)
    }
    var canHighlight: Bool {
        guard let document, document.allowsCopying, document.allowsCommenting, !document.isLocked, !document.isEncrypted,
              view?.document === document, let selection = view?.currentSelection else { return false }
        return !selection.pages.isEmpty && selection.pages.allSatisfy { $0.document === document } && selection.string?.isEmpty == false
    }
    func toggleEditing() {
        if isEditing { isEditing = false; drawingTool = nil; return }
        guard let document else { return }
        do {
            try PDFEditing.validate(document, assembly: !document.allowsCommenting, annotationsOnly: document.allowsCommenting, allowSignatureChanges: true)
            let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true); commentGraph = graph
            try graph.validateAnnotationSave()
            editingError = nil; isEditing = true
        } catch { editingError = error.localizedDescription }
    }
    func dismissEditingError() { editingError = nil }

    func rotateVisiblePages(clockwise: Bool) {
        if showsOverview { rotateOverviewPages(clockwise: clockwise) }
        else { rotateCurrentPage(clockwise: clockwise) }
    }
    func rotateCurrentPage(clockwise: Bool) {
        guard let document, view?.document === document, let page = view?.currentPage else { return }
        applyRotations([(page, page.rotation + (clockwise ? 90 : -90))])
    }
    func rotateOverviewPages(clockwise: Bool) {
        guard let document else { return }
        let pages = PDFPageAssembly.pages(document).filter { selectedOverviewPages.contains(ObjectIdentifier($0)) }
        applyRotations(pages.map { ($0, $0.rotation + (clockwise ? 90 : -90)) })
    }
    private func applyRotations(_ rotations: [(PDFPage, Int)]) {
        guard allowProtectedEdit() else { return }
        guard let document, !rotations.isEmpty else { return }
        do {
            guard draftPage == nil else { throw PDFPageAssembly.Failure.draft }
            try PDFEditing.validate(document, assembly: true, allowSignatureChanges: true)
            let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true); commentGraph = graph
            let previous = rotations.map { ($0.0, $0.0.rotation) }
            let bytes = try PDFPageAssembly.rotated(rotations, in: document, graph: graph, sourceData: hasPendingAnnotations ? nil : inputData)
            for (page, rotation) in rotations { page.rotation = (rotation % 360 + 360) % 360 }
            pageRevision = UUID(); acceptEdit(bytes)
            undoManager?.registerUndo(withTarget: self) { target in target.applyRotations(previous) }
            undoManager?.setActionName(rotations.count == 1 ? "Rotate Page" : "Rotate Pages")
            view?.layoutDocumentView(); view?.needsDisplay = true
        } catch { editingError = error.localizedDescription }
    }

    @discardableResult func select(_ selection: PDFSelection) -> Bool {
        guard let document, view?.document === document, !selection.pages.isEmpty,
              selection.pages.allSatisfy({ $0.document === document }) else { return false }
        view?.setCurrentSelection(selection, animate: false); return true
    }
    func highlightSelection(color: HighlightColor = .yellow) {
        guard allowProtectedEdit() else { return }
        guard let document, view?.document === document, let selection = view?.currentSelection else { return }
        do { applyHighlights(try PDFEditing.highlights(for: selection, in: document, color: color), adding: true) }
        catch { editingError = error.localizedDescription }
    }
    func deleteAnnotation(_ comment: Comment) {
        guard allowProtectedEdit() else { return }
        guard let document, comment.page.document === document, comment.annotation.page === comment.page,
              comment.page.annotations.contains(where: { $0 === comment.annotation }),
              Self.isReviewComment(comment.annotation) || ["Highlight", "Underline", "Squiggly", "StrikeOut", "Ink", "Square", "Circle"].contains(comment.annotation.type ?? "") else { return }
        let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true); commentGraph = graph
        let annotations = comment.page.annotations
        var ordered = [comment.annotation], index = 0, seen: Set<ObjectIdentifier> = [ObjectIdentifier(comment.annotation)]
        while index < ordered.count {
            let parent = ObjectIdentifier(ordered[index]); index += 1
            for child in annotations where graph.parent(of: child) == parent && seen.insert(ObjectIdentifier(child)).inserted { ordered.append(child) }
        }
        let changes = ordered.map { note in (note: note, page: comment.page, parent: graph.parent(of: note).flatMap { id in annotations.first { ObjectIdentifier($0) == id } }) }
        applyAnnotationChanges(changes, adding: false, name: ["Ink", "Square", "Circle"].contains(comment.annotation.type ?? "") ? "Delete Drawing" : ["Highlight", "Underline", "Squiggly", "StrikeOut"].contains(comment.annotation.type ?? "") ? "Delete Highlight" : ordered.count > 1 ? "Delete Comment Thread" : "Delete Comment")
    }
    func deleteHighlight(_ annotation: PDFAnnotation) {
        guard let document, let page = annotation.page, page.document === document,
              ["Highlight", "Underline", "Squiggly", "StrikeOut", "Ink", "Square", "Circle"].contains(annotation.type ?? "") else { return }
        deleteAnnotation(Comment(id: ObjectIdentifier(annotation), annotation: annotation, page: page, pageNumber: document.index(for: page) + 1, author: annotation.userName ?? "", text: annotation.contents ?? "", parent: nil))
    }
    private func applyAnnotationChanges(_ changes: [(note: PDFAnnotation, page: PDFPage, parent: PDFAnnotation?)], adding: Bool, name: String) {
        guard allowProtectedEdit() else { return }
        guard let document else { return }
        do {
            try PDFEditing.validate(document, annotationsOnly: true)
            let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true); commentGraph = graph
            try PDFNotes.change(changes, in: document, adding: adding, graph: graph)
            acceptPendingAnnotation()
            undoManager?.registerUndo(withTarget: self) { target in target.applyAnnotationChanges(changes, adding: !adding, name: name) }
            undoManager?.setActionName(name)
            if let draftParent, changes.contains(where: { $0.note === draftParent }) { cancelComment() }
            view?.needsDisplay = true
        } catch { editingError = error.localizedDescription }
    }
    func addDrawing(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard allowProtectedEdit() else { return }
        guard isEditing, let document, page.document === document, ["Ink", "Square", "Circle"].contains(annotation.type ?? "") else { return }
        applyHighlights([(page, annotation)], adding: true, name: "Draw on PDF")
    }
    private func applyHighlights(_ highlights: [(PDFPage, PDFAnnotation)], adding: Bool, name: String = "Highlight Text") {
        guard allowProtectedEdit() else { return }
        guard let document else { return }
        do {
            let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true); commentGraph = graph
            try PDFEditing.validate(document, annotationsOnly: true)
            try PDFNotes.change(highlights.map { ($0.1, $0.0, nil) }, in: document, adding: adding, graph: graph)
            acceptPendingAnnotation()
            undoManager?.registerUndo(withTarget: self) { target in target.applyHighlights(highlights, adding: !adding, name: name) }
            undoManager?.setActionName(name)
            view?.clearSelection(); view?.needsDisplay = true
        } catch { editingError = error.localizedDescription }
    }

    var canArrangePages: Bool {
        guard let document else { return false }
        return !document.isLocked && !document.isEncrypted && document.allowsDocumentAssembly
    }
    func pageDragToken(_ page: PDFPage) -> String { "\(pageRevision.uuidString)|\(ObjectIdentifier(page))" }
    func selectOverviewPage(_ page: PDFPage) {
        guard let document, page.document === document else { return }
        currentPage = document.index(for: page) + 1
    }
    func openOverviewPage(_ page: PDFPage) {
        selectOverviewPage(page)
        showsOverview = false
        revealLibraryPage(currentPage, terms: [])
    }
    func arrangePage(token: String, before target: PDFPage?) { arrangePages(tokens: [token], before: target) }
    func arrangePages(tokens: [String], before target: PDFPage?) {
        guard let document else { return }
        let pages = PDFPageAssembly.pages(document)
        let selected = pages.filter { tokens.contains(pageDragToken($0)) }
        guard !tokens.isEmpty, Set(tokens).count == tokens.count, selected.count == tokens.count,
              target == nil || pages.contains(where: { $0 === target }) else {
            editingError = PDFPageAssembly.Failure.stale.localizedDescription; return
        }
        let positions = Set(selected.map(ObjectIdentifier.init))
        let insertion = target.flatMap { target in pages.firstIndex(where: { $0 === target }) } ?? pages.count
        let preceding = pages.prefix(insertion).filter { !positions.contains(ObjectIdentifier($0)) }.count
        var order = pages.filter { !positions.contains(ObjectIdentifier($0)) }
        order.insert(contentsOf: selected, at: preceding)
        applyPageOrder(order, selected: selected.first, sources: [], action: selected.count == 1 ? "Move Page" : "Move Pages", selection: positions)
    }
    func insertPDFs(_ urls: [URL], before target: PDFPage? = nil) {
        guard allowProtectedEdit() else { return }
        guard let document else { return }
        do {
            guard draftPage == nil else { throw PDFPageAssembly.Failure.draft }
            try PDFEditing.validate(document, assembly: true, allowSignatureChanges: true)
            var pages = PDFPageAssembly.pages(document)
            guard target == nil || pages.contains(where: { $0 === target }) else { throw PDFPageAssembly.Failure.stale }
            let (imported, graphs, sources) = try PDFPageAssembly.imported(urls, allowSignatureChanges: true)
            if sources.contains(where: PDFEditing.hasDigitalSignature), !protection.requiresConsent {
                protection.requireConsent(); objectWillChange.send()
                guard allowProtectedEdit() else { return }
            }
            guard pages.count + imported.count <= 10000 else { throw PDFPageAssembly.Failure.size }
            let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true); commentGraph = graph
            for other in graphs { try graph.merge(other) }
            let position = target.flatMap { target in pages.firstIndex(where: { $0 === target }) } ?? pages.count
            pages.insert(contentsOf: imported, at: position)
            applyPageOrder(pages, selected: imported.first, sources: sources, action: "Insert PDF Pages", selection: Set(imported.map(ObjectIdentifier.init)))
        } catch { editingError = error.localizedDescription }
    }
    func choosePDFs(before target: PDFPage? = nil) {
        guard allowProtectedEdit() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.message = target == nil ? "Append PDF pages to this document." : "Insert PDF pages before this page."
        let revision = pageRevision
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            guard revision == self.pageRevision else { self.editingError = PDFPageAssembly.Failure.stale.localizedDescription; return }
            self.insertPDFs(panel.urls, before: target)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func applyPageOrder(_ pages: [PDFPage], selected: PDFPage?, sources: [PDFDocument], action: String, selection: Set<ObjectIdentifier>? = nil) {
        guard allowProtectedEdit() else { return }
        guard let document else { return }
        do {
            guard draftPage == nil else { throw PDFPageAssembly.Failure.draft }
            let before = PDFPageAssembly.pages(document)
            if before.elementsEqual(pages, by: { $0 === $1 }) { return }
            let previousSelection = document.page(at: max(0, currentPage - 1))
            let previousGroup = selectedOverviewPages
            let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true); commentGraph = graph
            stop()
            let bytes = try PDFPageAssembly.apply(pages, in: document, graph: graph, sourceData: hasPendingAnnotations ? nil : inputData)
            pageRevision = UUID()
            matches = []; cancelComment(); activeCitation = nil; citationStatus = nil
            if sources.contains(where: PDFEditing.hasDigitalSignature) { openedWithSignature = true }
            acceptEdit(bytes)
            currentPage = selected.map { document.index(for: $0) + 1 } ?? 1
            selectedOverviewPages = selection ?? Set(selected.map { [ObjectIdentifier($0)] } ?? [])
            undoManager?.registerUndo(withTarget: self) { target in
                target.applyPageOrder(before, selected: previousSelection, sources: sources, action: action, selection: previousGroup)
            }
            undoManager?.setActionName(action)
            view?.layoutDocumentView(); view?.needsDisplay = true
            if let selected { view?.go(to: selected) }
            if !query.isEmpty { search() }
        } catch { editingError = error.localizedDescription }
    }

    private struct PageState {
        let document: PDFDocument
        let graph: PDFCommentGraph
        let bytes: Data
        let page: Int
        let selection: Set<ObjectIdentifier>
    }
    func fitPages(to paper: CGSize) {
        guard allowProtectedEdit() else { return }
        guard let document else { return }
        do {
            guard draftPage == nil else { throw PDFPageAssembly.Failure.draft }
            let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true); commentGraph = graph
            let bytes = try PDFPageSizing.apply(document, graph: graph, sourceData: inputData, paper: paper)
            guard let fitted = PDFDocument(data: bytes) else { throw PDFEditing.Failure.invalid }
            let indexes = PDFPageAssembly.pages(document).enumerated().filter { selectedOverviewPages.contains(ObjectIdentifier($0.element)) }.map(\.offset)
            let selection = Set(indexes.compactMap { fitted.page(at: $0).map(ObjectIdentifier.init) })
            try restorePageState(PageState(document: fitted, graph: PDFCommentGraph(document: fitted, sourceData: bytes, allowSignatureChanges: true), bytes: bytes, page: currentPage, selection: selection))
        } catch { editingError = error.localizedDescription }
    }
    private func restorePageState(_ state: PageState) throws {
        guard let document else { return }
        let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true)
        let previous = PageState(document: document, graph: graph, bytes: try hasPendingAnnotations ? graph.serialize(document) : (inputData ?? graph.serialize(document)), page: currentPage, selection: selectedOverviewPages)
        stop(); self.document = state.document; commentGraph = state.graph
        currentPage = state.page; selectedOverviewPages = state.selection
        pageRevision = UUID(); matches = []; activeCitation = nil; citationStatus = nil
        cancelComment(); acceptEdit(state.bytes)
        view?.document = state.document
        if let page = state.document.page(at: max(0, state.page - 1)) { view?.go(to: page) }
        undoManager?.registerUndo(withTarget: self) { target in
            do { try target.restorePageState(previous) } catch { target.editingError = error.localizedDescription }
        }
        undoManager?.setActionName("Fit Page Sizes")
        if !query.isEmpty { search() }
    }

    /// No full PDF byte buffers or temporary files are produced for individual reader strokes.
    private func acceptPendingAnnotation() {
        hasPendingAnnotations = true; pendingAnnotationRevision = UUID(); editingError = nil
        commentGeneration = UUID(); commentTask?.cancel(); commentTask = nil
        commentsLoaded = false
        if showsSidebar && (sidebar == .comments || sidebar == .highlights) { loadComments() }
    }
    func prepareSave() throws -> Data {
        guard let document else { throw PDFEditing.Failure.invalid }
        guard hasPendingAnnotations else { return inputData ?? Data() }
        let graph = commentGraph ?? PDFCommentGraph(document: document, sourceData: inputData, allowSignatureChanges: true)
        commentGraph = graph
        let bytes = try graph.serialize(document)
        acceptEdit(bytes)
        return bytes
    }
    func discardChanges(to data: Data) {
        inputData = nil
        load(data)
    }

    private func acceptEdit(_ bytes: Data) {
        hasPendingAnnotations = false
        inputData = bytes; committedData = bytes; editingError = nil
        commentGeneration = UUID(); commentTask?.cancel(); commentTask = nil
        commentsLoaded = false
        if showsSidebar && (sidebar == .comments || sidebar == .highlights) { loadComments() }
    }

    func makePrintOperation() throws -> NSPrintOperation {
        guard let document, !document.isLocked, document.allowsPrinting,
              let info = NSPrintInfo.shared.copy() as? NSPrintInfo,
              let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { throw PDFEditing.Failure.printing }
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        return operation
    }
    func printDocument() {
        do {
            let operation = try makePrintOperation()
            if let window = view?.window { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
            else { operation.run() }
        } catch { editingError = error.localizedDescription }
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
    func goToPage(_ number: Int) { if number > 0, let page = document?.page(at: number - 1) { if showsOverview { openOverviewPage(page) } else { view?.go(to: page) } } }
    func goToOutline(_ destination: PDFDestination) {
        guard let document, let page = destination.page, page.document === document else { return }
        currentPage = document.index(for: page) + 1
        showsOverview = false
        libraryDestination = (currentPage, [], nil, false)
        view?.go(to: destination)
    }
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
