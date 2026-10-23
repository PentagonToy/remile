import AppKit
import Combine
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class HomeModel: ObservableObject {
    let reader = ReadingSession()
    let overleaf: OverleafLibrary
    @Published var texProject: TeXProject?
    let assistant = DocumentAssistant(historyKey: "search")
    enum Page { case home, search, reference }
    let references = ReferenceModel()
    @Published var opening = false
    let pdfSearchEditing = SearchPDFModel()
    @Published var page: Page = .home
    @Published var resultOrder = SearchResultOrder.relevance
    @Published var summary = LibrarySummary()
    @Published var query = ""
    @Published var results: [LibraryHit] = [] { didSet { groupedResults = nil; rankedResults = nil } }
    @Published var selectedHit: LibraryHit?
    @Published var documentFilter = "" { didSet { groupedResults = nil; rankedResults = nil } }
    @Published var expandedDocuments = Set<String>()
    private var groupedResults: [SearchResultGroup]?
    private var rankedResults: [RankedSearchHit]?
    var resultGroups: [SearchResultGroup] {
        if let groupedResults { return groupedResults }
        let value = SearchResultGroup.make(results, filter: documentFilter); groupedResults = value; return value
    }
    var rankedHits: [RankedSearchHit] {
        if let rankedResults { return rankedResults }
        let value = RankedSearchHit.make(results, filter: documentFilter); rankedResults = value; return value
    }
    var visibleHits: [LibraryHit] { resultOrder == .rank ? rankedHits.map(\.hit) : resultGroups.flatMap(\.hits) }
    @Published var libraryPresented = false
    @Published var guidePresented = false
    @Published var askPresented = false
    @Published var boosting = false
    @Published var boostApplied = false
    private let searchBoost = SearchBoost()
    @Published var exploring = false
    @Published var exploredQueries: [String] = []
    @Published var spellingSuggestions: [String] = []
    @Published var libraryRevision = UUID()
    @Published var searching = false
    @Published private(set) var searchStartedAt = Date()
    @Published private(set) var searchDuration: TimeInterval?
    @Published var queryError: String?
    @Published var indexing = false
    @Published var processing = false
    @Published var progress: LibraryProgress?
    @Published var message: String?
    @Published var error: String?
    @Published var recent: [URL] = []
    @Published var conversion = ConversionModel()
    @Published var compression = CompressionModel()
    @Published var convertPresented = false
    @Published var compressPresented = false
    @Published var combinePresented = false
    @Published var combination = CombinationModel()
    let index: LibraryIndex
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private struct SearchStamp: Equatable {
        let query: String
        let revision: UUID
        let provider: String
        let boosting: Bool
        let offline: Bool
        let corrections: Bool
    }
    private var previousSearch: SearchStamp?
    private var currentSearch: SearchStamp {
        SearchStamp(query: query.trimmingCharacters(in: .whitespacesAndNewlines), revision: libraryRevision,
                    provider: UserDefaults.standard.string(forKey: "assistant.provider") ?? "Apple Intelligence",
                    boosting: SearchBoostPolicy.enabled(), offline: NetworkAccess.offline,
                    corrections: UserDefaults.standard.object(forKey: SearchQuestion.spellingPreference) as? Bool ?? true)
    }

    var hasSubmittedSearch: Bool { previousSearch == currentSearch && searchDuration != nil }

    /// A draft never starts retrieval. Return is the explicit submission boundary.
    func editSearch() {
        if previousSearch?.query != query.trimmingCharacters(in: .whitespacesAndNewlines) { invalidateSearch() }
    }
    func invalidateSearch() {
        guard !pdfSearchEditing.hasPendingEdits else { return }
        cancelExploration(); previousSearch = nil
        results = []; selectedHit = nil; searchDuration = nil; queryError = nil
        spellingSuggestions = []; exploredQueries = []; boostApplied = false
    }
    /// Returning from a document reuses completed results, selection, order and timing.
    func resumeSearch() {
        if previousSearch != currentSearch { invalidateSearch() }
    }
    private var access: [URL] = []

    init(index: LibraryIndex = LibraryIndex(), overleaf: OverleafLibrary? = nil) { self.index = index; self.overleaf = overleaf ?? OverleafLibrary() }

    func load() async {
        refreshRecent()
        do {
            summary = try await index.summary()
            // Keep selected folder grants alive while this shared home model exists.
            for url in access { url.stopAccessingSecurityScopedResource() }
            access = summary.folders.compactMap { folder in
                guard let url = try? folder.url(), url.startAccessingSecurityScopedResource() else { return nil }
                return url
            }
        } catch { self.error = error.localizedDescription }
    }

    func addFolder() {
        guard !indexing else { return }
        let panel = NSOpenPanel()
        panel.title = "Add to Library"
        panel.prompt = "Add to Library"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        libraryPresented = true
        Task {
            do { try await index.add(url); await load(); refresh() }
            catch { self.error = error.localizedDescription }
        }
    }

    func removeFolder(_ folder: LibraryFolder) {
        guard !indexing else { return }
        Task {
            do { let root = try folder.url(); try ManuscriptReviewStore.removeLibraryFolder(root); try await index.remove(folder); await load(); invalidateSearch() }
            catch { self.error = error.localizedDescription }
        }
    }

    func reindex(_ folder: LibraryFolder) { refresh(folderID: folder.id, force: true) }

    func refresh(folderID: String? = nil, force: Bool = false) {
        guard !indexing, !summary.folders.isEmpty else { return }
        indexing = true; progress = nil; message = nil
        indexTask = Task {
            do {
                try await index.refresh(folderID: folderID, force: force) { [weak self] value in await self?.showProgress(value) }
                message = "Index up to date."
            } catch is CancellationError { message = "Indexing stopped." }
            catch { self.error = error.localizedDescription }
            indexing = false; progress = nil; indexTask = nil; libraryRevision = UUID()
            await load(); invalidateSearch()
        }
    }
    private func showProgress(_ value: LibraryProgress) { progress = value }
    func cancelIndexing() { indexTask?.cancel() }

    func search(immediate: Bool = false) {
        guard pdfSearchEditing.confirmLeaving() else { return }
        previousSearch = currentSearch
        searchTask?.cancel()
        let generation = UUID(); searchGeneration = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = ProcessInfo.processInfo.systemUptime
        searchStartedAt = Date(); searchDuration = nil
        results = []; selectedHit = nil; queryError = nil; searching = !text.isEmpty
        exploring = false; exploredQueries = []; spellingSuggestions = []; boostApplied = false
        boosting = !text.isEmpty && SearchBoostPolicy.canUse(query: text)
        guard !text.isEmpty else { return }
        let offerCorrections = UserDefaults.standard.object(forKey: SearchQuestion.spellingPreference) as? Bool ?? true
        searchTask = Task {
            do {
                let response = try await librarySearch(text)
                let hits = response.hits
                let suggestions = offerCorrections && hits.isEmpty ? try await index.spellingSuggestions(text) : []
                try Task.checkCancellation()
                guard generation == searchGeneration else { return }
                searchDuration = ProcessInfo.processInfo.systemUptime - started
                results = hits; spellingSuggestions = suggestions; searching = false; boosting = false; boostApplied = !response.phrases.isEmpty; expandedDocuments = []
                selectResult(visibleHits.first)
            } catch is CancellationError { }
            catch {
                guard generation == searchGeneration else { return }
                searchDuration = ProcessInfo.processInfo.systemUptime - started
                searching = false; boosting = false; queryError = error.localizedDescription
            }
        }
    }

    /// The CLI and UI share one engine and policy; a failed or paused boost returns B0.
    func librarySearch(_ text: String, boost: Bool = true) async throws -> (hits: [LibraryHit], phrases: [String]) {
        let original = try await index.rankedSearch(text)
        guard boost, SearchBoostPolicy.canUse(query: text) else { return (original, []) }
        do {
            let phrases = try await searchBoost.phrases(for: text)
            try Task.checkCancellation()
            guard !phrases.isEmpty, SearchBoostPolicy.canUse(query: text) else { return (original, []) }
            let hits = try await index.rankedSearch(text, expansions: phrases)
            try Task.checkCancellation()
            guard SearchBoostPolicy.canUse(query: text) else { return (original, []) }
            return (hits, phrases)
        } catch {
            try Task.checkCancellation()
            return (original, [])
        }
    }

    func explore() {
        guard pdfSearchEditing.confirmLeaving() else { return }
        guard !NetworkAccess.offline else { search(immediate: true); return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !exploring else { return }
        let engine = AssistantEngine.selected, state = engine.status()
        guard state.ready else { queryError = state.message; return }
        previousSearch = currentSearch
        searchTask?.cancel(); let generation = UUID(); searchGeneration = generation
        let started = ProcessInfo.processInfo.systemUptime
        searchStartedAt = Date(); searchDuration = nil
        exploring = true; searching = false; boosting = false; boostApplied = false; queryError = nil; spellingSuggestions = []
        searchTask = Task {
            do {
                let original = try await index.search(text)
                let vocabulary = try await index.explorationVocabulary()
                let queries = try await SearchExpansion.plan(query: text, vocabulary: vocabulary, engine: engine)
                var lists = [(text, original)], used: [String] = []
                for planned in queries where planned.caseInsensitiveCompare(text) != .orderedSame {
                    try Task.checkCancellation()
                    var matched = planned, hits = try await index.search(planned)
                    if hits.isEmpty, let grounded = SearchExpansion.groundedQuery(planned, vocabulary: vocabulary), grounded != planned {
                        matched = grounded; hits = try await index.search(grounded)
                    }
                    if !hits.isEmpty && !used.contains(matched) { lists.append((matched, hits)); used.append(matched) }
                }
                if used.isEmpty, let grounded = SearchExpansion.groundedQuery(text, vocabulary: vocabulary), grounded.caseInsensitiveCompare(text) != .orderedSame {
                    let hits = try await index.search(grounded)
                    if !hits.isEmpty { lists.append((grounded, hits)); used.append(grounded) }
                }
                try Task.checkCancellation(); guard generation == searchGeneration else { return }
                results = SearchExpansion.merge(lists); exploredQueries = used; expandedDocuments = []
                searchDuration = ProcessInfo.processInfo.systemUptime - started
                exploring = false
                if used.isEmpty { queryError = "No related matches." }
                selectResult(visibleHits.first)
            } catch {
                guard generation == searchGeneration else { return }
                searchDuration = error is CancellationError ? nil : ProcessInfo.processInfo.systemUptime - started
                exploring = false
                queryError = error is CancellationError ? nil : "Unable to explore. Keyword search is still available."
            }
        }
    }
    func cancelExploration() {
        searchTask?.cancel(); searchGeneration = UUID(); exploring = false; searching = false; boosting = false
    }

    func selectResult(_ hit: LibraryHit?) {
        if selectedHit?.path != hit?.path, !pdfSearchEditing.confirmLeaving() { return }
        selectedHit = hit
        if let hit { expandedDocuments.insert(hit.path) }
    }
    func filterDocuments() {
        if !visibleHits.contains(where: { $0.id == selectedHit?.id }) { selectResult(visibleHits.first) }
    }
    func moveResult(_ delta: Int) {
        let hits = visibleHits
        guard let index = hits.firstIndex(where: { $0.id == selectedHit?.id }), hits.indices.contains(index + delta) else { return }
        selectResult(hits[index + delta])
    }
    var resultPosition: Int? { visibleHits.firstIndex { $0.id == selectedHit?.id } }

    func open(_ url: URL) {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { openTeX(url); return }
        if url.pathExtension.lowercased() == "tex" { openTeX(url.deletingLastPathComponent()); return }
        guard closeTeX(), !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                try reader.open(url, data: data)
                if reader.url == url { recordRecent(url) }
            } catch { self.error = error.localizedDescription }
        }
    }

    private static let recentPreference = "reader.recentDocuments"
    private static let hiddenRecentPreference = "reader.hiddenRecentDocuments"
    func removeRecent(_ url: URL) {
        let path = url.standardizedFileURL.path
        recent.removeAll { $0.standardizedFileURL.path == path }
        var hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenRecentPreference) ?? [])
        let system = Set(NSDocumentController.shared.recentDocumentURLs.map { $0.standardizedFileURL.path })
        hidden = hidden.intersection(system); hidden.insert(path)
        UserDefaults.standard.set(Array(hidden), forKey: Self.hiddenRecentPreference)
        UserDefaults.standard.set(recent.map(\.path), forKey: Self.recentPreference)
        var dates = UserDefaults.standard.dictionary(forKey: "reader.lastOpened") ?? [:]
        dates.removeValue(forKey: path); UserDefaults.standard.set(dates, forKey: "reader.lastOpened")
    }
    func clearRecent() {
        recent = []; UserDefaults.standard.removeObject(forKey: Self.recentPreference); UserDefaults.standard.removeObject(forKey: "reader.lastOpened")
        UserDefaults.standard.removeObject(forKey: Self.hiddenRecentPreference)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
    func refreshRecent() {
        let saved = (UserDefaults.standard.stringArray(forKey: Self.recentPreference) ?? []).map { URL(fileURLWithPath: $0) }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenRecentPreference) ?? [])
        recent = Self.unique(saved + NSDocumentController.shared.recentDocumentURLs).filter { !hidden.contains($0.standardizedFileURL.path) }
    }
    func lastOpened(_ url: URL) -> Date? {
        (UserDefaults.standard.dictionary(forKey: "reader.lastOpened")?[url.standardizedFileURL.path] as? Double).map(Date.init(timeIntervalSince1970:))
    }
    private func recordRecent(_ url: URL) {
        var hidden = UserDefaults.standard.stringArray(forKey: Self.hiddenRecentPreference) ?? []
        hidden.removeAll { $0 == url.standardizedFileURL.path }
        UserDefaults.standard.set(hidden, forKey: Self.hiddenRecentPreference)
        var dates = UserDefaults.standard.dictionary(forKey: "reader.lastOpened") ?? [:]
        dates[url.standardizedFileURL.path] = Date().timeIntervalSince1970
        recent = Self.unique([url] + recent + NSDocumentController.shared.recentDocumentURLs).filter { !hidden.contains($0.standardizedFileURL.path) }
        let retained = Set(recent.map { $0.standardizedFileURL.path })
        UserDefaults.standard.set(dates.filter { retained.contains($0.key) }, forKey: "reader.lastOpened")
        UserDefaults.standard.set(recent.map(\.path), forKey: Self.recentPreference)
    }
    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return Array(urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }.prefix(20))
    }

    @discardableResult func closeTeX() -> Bool {
        guard pdfSearchEditing.confirmLeaving() else { return false }
        guard texProject?.confirmLeaving() != false else { return false }
        texProject?.releaseWorkspaceResources(); texProject = nil; return true
    }
    func chooseTeX() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.title = "Open LaTeX Project"
        if panel.runModal() == .OK, let url = panel.url {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true && url.pathExtension.lowercased() == "zip" { importTeXArchive(url) }
            else { openTeX(url.pathExtension.lowercased() == "tex" ? url.deletingLastPathComponent() : url) }
        }
    }
    func openTeX(_ root: URL) {
        do { let connection = overleaf.connection(for: root); let project = try TeXProject(root, historyEnabled: connection == nil, displayName: connection?.name); guard reader.close(), closeTeX() else { return }; texProject = project
            if let connection { project.renameConnectedProject = { [weak library = overleaf] name in
                guard let library else { throw OverleafProjectRename.Failure.unavailable }
                try await library.renameProject(connection.id, to: name)
            } }
            project.renamedRoot = { [weak self] old, new in self?.recent.removeAll { $0 == old }; self?.recordRecent(new) }
            recordRecent(project.root); project.compile() }
        catch { self.error = "Unable to open LaTeX project: " + error.localizedDescription }
    }
    func newMarkdown() { guard closeTeX(), !opening else { return }; if reader.newMarkdown() { page = .home } }

    func chooseDocument() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ReadingDocument.readableContentTypes
        panel.prompt = "Open"; panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func create(_ operation: DocumentOperation, inputs supplied: [URL]? = nil, open: @escaping (URL) -> Void) {
        if operation == .combine { combination = CombinationModel(inputs: supplied ?? []); combinePresented = true; return }
        guard !processing else { return }
        let inputs: [URL]
        if let supplied { inputs = supplied }
        else {
            let panel = NSOpenPanel()
            panel.title = operation == .images ? "Choose images in page order" : "Choose documents to combine"
            panel.allowedContentTypes = operation == .images ? [.image] : [.pdf]
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            inputs = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        let confirmation = NSAlert()
        confirmation.messageText = operation == .images ? "Create a document from these images?" : "Combine these documents?"
        confirmation.informativeText = "Page order:\n" + inputs.map(\.lastPathComponent).joined(separator: "\n") + (operation == .combine ? "\n\nPage annotations are copied. Document bookmarks and internal links may change. Signed, encrypted, form and threaded-comment documents are not supported." : "")
        confirmation.addButton(withTitle: "Continue"); confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.pdf]; save.nameFieldStringValue = operation == .images ? "Images.pdf" : "Combined.pdf"
        guard save.runModal() == .OK, let destination = save.url else { return }
        guard !inputs.contains(where: { $0.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }) else {
            error = "Choose a new filename to keep the original documents."; return
        }
        processing = true; message = "Creating your document…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try DocumentTools.create(operation, inputs: inputs, destination: destination) }.value
                message = "Document created."; open(destination)
            } catch { self.error = error.localizedDescription; message = nil }
            processing = false
        }
    }
}

/// Pending requests also cover a document window that has not mounted its PDFView yet.
final class ReaderNavigation: ObservableObject {
    static let shared = ReaderNavigation()
    struct Request { let id = UUID(); let path: String; let page: Int; let terms: [String]; var noteExcerpt: String? = nil }
    @Published var request: Request?
    func reveal(_ hit: LibraryHit, query: String, noteExcerpt: String? = nil) {
        request = Request(path: hit.path, page: hit.page, terms: (hit.matchQuery ?? query).replacingOccurrences(of: "\"", with: "").split(whereSeparator: \.isWhitespace).map(String.init), noteExcerpt: noteExcerpt)
    }
}
