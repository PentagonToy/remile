import AppKit
import Combine
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class HomeModel: ObservableObject {
    let reader = ReadingSession()
    let assistant = DocumentAssistant(historyKey: "search")
    enum Page { case home, search }
    @Published var opening = false
    @Published var page: Page = .home
    @Published var resultOrder = SearchResultOrder.relevance
    @Published var summary = LibrarySummary()
    @Published var query = ""
    @Published var results: [LibraryHit] = []
    @Published var selectedHit: LibraryHit?
    @Published var documentFilter = ""
    @Published var expandedDocuments = Set<String>()
    var resultGroups: [SearchResultGroup] { SearchResultGroup.make(results, filter: documentFilter, order: resultOrder) }
    var visibleHits: [LibraryHit] { resultGroups.flatMap(\.hits) }
    @Published var libraryPresented = false
    @Published var askPresented = false
    @Published var exploring = false
    @Published var exploredQueries: [String] = []
    @Published var spellingSuggestions: [String] = []
    @Published var libraryRevision = UUID()
    @Published var searching = false
    @Published var queryError: String?
    @Published var indexing = false
    @Published var processing = false
    @Published var progress: LibraryProgress?
    @Published var message: String?
    @Published var error: String?
    @Published var recent: [URL] = []
    @Published var plannedTool: String?
    @Published var conversion = ConversionModel()
    @Published var compression = CompressionModel()
    @Published var convertPresented = false
    @Published var compressPresented = false
    let index: LibraryIndex
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var access: [URL] = []

    init(index: LibraryIndex = LibraryIndex()) { self.index = index }

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
            do { try await index.remove(folder); await load(); search() }
            catch { self.error = error.localizedDescription }
        }
    }

    func refresh() {
        guard !indexing, !summary.folders.isEmpty else { return }
        indexing = true; progress = nil; message = nil
        indexTask = Task {
            do {
                try await index.refresh { [weak self] value in await self?.showProgress(value) }
                message = "Index up to date."
            } catch is CancellationError { message = "Indexing stopped." }
            catch { self.error = error.localizedDescription }
            indexing = false; progress = nil; indexTask = nil; libraryRevision = UUID()
            await load(); search()
        }
    }
    private func showProgress(_ value: LibraryProgress) { progress = value }
    func cancelIndexing() { indexTask?.cancel() }

    func search() {
        searchTask?.cancel()
        let generation = UUID(); searchGeneration = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; selectedHit = nil; queryError = nil; searching = !text.isEmpty
        exploring = false; exploredQueries = []; spellingSuggestions = []
        guard !text.isEmpty else { return }
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let hits = try await index.search(text)
                let suggestions = hits.isEmpty ? try await index.spellingSuggestions(text) : []
                try Task.checkCancellation()
                guard generation == searchGeneration else { return }
                results = hits; spellingSuggestions = suggestions; searching = false; expandedDocuments = []
                selectResult(visibleHits.first)
            } catch is CancellationError { }
            catch {
                guard generation == searchGeneration else { return }
                searching = false; queryError = error.localizedDescription
            }
        }
    }

    func explore() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !exploring else { return }
        let state = AppleIntelligence.status()
        guard state.ready else { queryError = state.message; return }
        searchTask?.cancel(); let generation = UUID(); searchGeneration = generation
        exploring = true; searching = false; queryError = nil; spellingSuggestions = []
        searchTask = Task {
            do {
                let original = try await index.search(text)
                let vocabulary = try await index.explorationVocabulary()
                let queries = try await SearchExpansion.plan(query: text, vocabulary: vocabulary)
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
                exploring = false
                if used.isEmpty { queryError = "No related matches." }
                selectResult(visibleHits.first)
            } catch {
                guard generation == searchGeneration else { return }
                exploring = false
                queryError = error is CancellationError ? nil : "Unable to explore. Keyword search is still available."
            }
        }
    }
    func cancelExploration() {
        searchTask?.cancel(); searchGeneration = UUID(); exploring = false; searching = false
    }

    func selectResult(_ hit: LibraryHit?) {
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
        guard !opening else { return }
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
    func refreshRecent() {
        let saved = (UserDefaults.standard.stringArray(forKey: Self.recentPreference) ?? []).map { URL(fileURLWithPath: $0) }
        recent = Self.unique(saved + NSDocumentController.shared.recentDocumentURLs)
    }
    private func recordRecent(_ url: URL) {
        recent = Self.unique([url] + recent + NSDocumentController.shared.recentDocumentURLs)
        UserDefaults.standard.set(recent.map(\.path), forKey: Self.recentPreference)
    }
    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return Array(urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }.prefix(20))
    }

    func chooseDocument() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ReadingDocument.readableContentTypes
        panel.prompt = "Open"; panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func create(_ operation: DocumentOperation, inputs supplied: [URL]? = nil, open: @escaping (URL) -> Void) {
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
    struct Request { let id = UUID(); let path: String; let page: Int; let terms: [String] }
    @Published var request: Request?
    func reveal(_ hit: LibraryHit, query: String) {
        request = Request(path: hit.path, page: hit.page, terms: query.replacingOccurrences(of: "\"", with: "").split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
