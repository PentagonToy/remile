import AppKit
import PDFKit
import SwiftUI

@MainActor
final class SearchPDFModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var color = HighlightColor.yellow
    @Published private(set) var selectionAvailable = false
    @Published private(set) var saving = false
    @Published private(set) var canUndoHighlight = false
    @Published var editMessage: String?
    @Published var citationMessage: String?
    private let highlightStore = PDFHighlightStore()
    private var digest: Data?
    private var undoData: Data?
    private var restoredPage: Int?
    private weak var view: PDFView?
    private var selectionObserver: NSObjectProtocol?
    private var path: String?
    private var revision: UUID?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private struct Loaded: @unchecked Sendable { let document: PDFDocument; let digest: Data }
    func show(_ hit: LibraryHit?, revision: UUID? = nil) {
        task?.cancel(); generation = UUID(); error = nil; citationMessage = nil
        guard let hit else { undoData = nil; canUndoHighlight = false; digest = nil; editMessage = nil; document = nil; path = nil; self.revision = nil; loading = false; return }
        if path == hit.path, self.revision == revision, document != nil { return }
        document = nil; path = nil; loading = true; restoredPage = nil; digest = nil; undoData = nil; canUndoHighlight = false; editMessage = nil; selectionAvailable = false
        let token = generation
        task = Task {
            let worker = Task.detached(priority: .userInitiated) { () throws -> Loaded in
                try Task.checkCancellation()
                let data = try Data(contentsOf: URL(fileURLWithPath: hit.path), options: .mappedIfSafe)
                guard let document = PDFDocument(data: data), !document.isLocked else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                return Loaded(document: document, digest: PDFHighlightStore.digest(data))
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, generation == token else { return }
                document = result.document; digest = result.digest; path = hit.path; self.revision = revision; loading = false
            } catch {
                guard generation == token else { return }
                loading = false; self.error = "Document unavailable. Update the Library index."
            }
        }
    }
    func attach(_ view: PDFView) {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        self.view = view
        selectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self, weak view] _ in
            MainActor.assumeIsolated { self?.selectionAvailable = view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        }
    }
    private func editableURL() -> URL? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard NSDocumentController.shared.document(for: url) == nil else { editMessage = "Close this PDF in the reader before editing here."; return nil }
        return url
    }
    func highlight(selection captured: PDFSelection? = nil, color chosenColor: HighlightColor? = nil) {
        guard !saving, let document, let selection = captured ?? view?.currentSelection, let digest, let url = editableURL() else { return }
        let regions = HighlightRegion.make(selection: selection, document: document), chosen = chosenColor ?? color
        guard !regions.isEmpty else { editMessage = "Select text to highlight."; return }
        saving = true; editMessage = nil
        Task {
            do {
                let result = try await highlightStore.add(url: url, expected: digest, regions: regions, color: chosen)
                if path == url.path && self.document === document {
                    rememberPage(in: document)
                    self.document = result.document; self.digest = result.digest; undoData = result.previous; canUndoHighlight = true; selectionAvailable = false
                }
            } catch { if path == url.path { editMessage = error.localizedDescription } }
            saving = false
        }
    }
    func undoHighlight() {
        guard !saving, let document, let data = undoData, let digest, let url = editableURL() else { return }
        saving = true; editMessage = nil
        Task {
            do {
                let restored = try await highlightStore.restore(url: url, expected: digest, data: data)
                if path == url.path && self.document === document {
                    rememberPage(in: document)
                    self.document = PDFDocument(data: data); self.digest = restored; undoData = nil; canUndoHighlight = false; selectionAvailable = false
                }
            } catch { if path == url.path { editMessage = error.localizedDescription } }
            saving = false
        }
    }
    private func rememberPage(in document: PDFDocument) {
        restoredPage = nil
        guard let page = view?.currentPage, page.document === document else { return }
        let index = document.index(for: page)
        if index != NSNotFound { restoredPage = index + 1 }
    }
    func takeRestoredPage() -> Int? { defer { restoredPage = nil }; return restoredPage }
    func close() {
        task?.cancel(); generation = UUID(); document = nil; path = nil; revision = nil; loading = false; restoredPage = nil; selectionAvailable = false; undoData = nil; digest = nil; canUndoHighlight = false; editMessage = nil
        citationMessage = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }; selectionObserver = nil; view = nil
    }
}

struct SearchPDFPreview: View {
    let hit: LibraryHit?
    let query: String
    let revision: UUID
    let open: (URL) -> Void
    var citation: AssistantCitation? = nil
    var askSelection: ((PDFSelectionContext) -> Void)? = nil
    @StateObject private var presentation = Presentation()
    private final class Presentation: ObservableObject { @Published var translation: SelectionTranslation? }
    @StateObject private var model = SearchPDFModel()
    @StateObject private var zoom = ReaderZoom()
    var body: some View {
        VStack(spacing: 0) {
            if let hit {
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.name).font(RemileType.heading).lineLimit(2).multilineTextAlignment(.leading).help(hit.name)
                            Text("Page \(hit.page)").font(RemileType.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { ReaderNavigation.shared.reveal(hit, query: query); open(URL(fileURLWithPath: hit.path)) } label: { Label("Open", systemImage: "arrow.up.right.square") }.fixedSize()
                    }
                    HStack(spacing: 12) {
                        ReaderZoomControls(zoom: zoom)
                        Spacer(minLength: 0)
                        if model.saving { ProgressView().controlSize(.small) }
                        Button { model.highlight() } label: { Image(systemName: "highlighter") }.help("Highlight selected text and save to PDF").accessibilityLabel("Highlight selected text").disabled(!model.selectionAvailable || model.saving)
                        Menu {
                            ForEach(HighlightColor.allCases) { color in
                                Button { model.color = color } label: { Label { Text(color.name) } icon: { Image(systemName: model.color == color ? "checkmark.circle.fill" : "circle.fill").foregroundStyle(Color(nsColor: color.color)) } }
                            }
                        } label: { Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: model.color.color)) }.help("Highlight colour · \(model.color.name)").accessibilityLabel("Highlight colour")
                        Button { model.undoHighlight() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndoHighlight || model.saving).help("Undo last highlight")
                    }.buttonStyle(.borderless)
                }.padding(14)
                if let message = model.editMessage { Text(message).font(RemileType.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 12) }
                if let message = model.citationMessage { Text(message).font(RemileType.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 12) }
                Divider()
                if model.loading { ProgressView("Loading PDF…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error = model.error { ContentUnavailableView(error, systemImage: "doc.badge.exclamationmark") }
                else if let document = model.document {
                    if hit.page > 0 && hit.page <= document.pageCount { SearchPDFCanvas(document: document, page: hit.page, query: query, editing: model, citation: citation, zoom: zoom, selectionActions: selectionActions(hit)) }
                    else { ContentUnavailableView("Page changed. Update the Library index.", systemImage: "arrow.clockwise") }
                }
            } else { ContentUnavailableView(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Search your library" : "Select a result", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: (hit?.id ?? "") + revision.uuidString) { model.show(hit, revision: revision) }.onDisappear { model.close() }
            .modifier(SelectionTranslationModifier(request: $presentation.translation))
    }
    private func selectionActions(_ hit: LibraryHit) -> PDFSelectionActions {
        PDFSelectionActions(highlight: { context, color in
            guard context.document === model.document else { return }; model.highlight(selection: context.selection, color: color)
        }, addNote: { context in
            guard context.document === model.document, let passage = context.passages(path: hit.path).first else { return }
            let destination = LibraryHit(path: hit.path, folderID: hit.folderID, page: passage.location.unit, excerpt: passage.text, score: 0)
            ReaderNavigation.shared.reveal(destination, query: "", noteExcerpt: passage.text); open(URL(fileURLWithPath: hit.path))
        }, ask: { context in
            guard context.document === model.document else { return }; askSelection?(context)
        }, translate: { context in
            guard context.document === model.document else { return }; presentation.translation = SelectionTranslation(text: context.text)
        }, canAnnotate: { _ in !model.saving })
    }
}

struct SearchPDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let query: String
    var editing: SearchPDFModel? = nil
    var citation: AssistantCitation? = nil
    var zoom: ReaderZoom? = nil
    var selectionActions = PDFSelectionActions()
    @MainActor final class Coordinator { var page = 0; var query = ""; var citationID: UUID?; let highlights = SearchPDFHighlights() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFSelectionView(); view.selectionActions = selectionActions; editing?.attach(view); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.pageOverlayViewProvider = context.coordinator.highlights
        zoom?.attach(view)
        view.displayDirection = .vertical; view.backgroundColor = .windowBackgroundColor
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        (view as? PDFSelectionView)?.selectionActions = selectionActions
        context.coordinator.highlights.update(query: query, citation: citation)
        let changed = view.document !== document
        if changed { view.document = document }
        guard changed || context.coordinator.page != page || context.coordinator.query != query || context.coordinator.citationID != citation?.id else { return }
        context.coordinator.page = page; context.coordinator.query = query; context.coordinator.citationID = citation?.id
        view.highlightedSelections = []
        let destination = changed ? editing?.takeRestoredPage() ?? page : page
        guard let target = document.page(at: destination - 1) else { return }
        let selections = citation.map { PDFCitation.selections(on: target, excerpt: $0.text) } ?? Self.selections(on: target, query: query)
        view.go(to: target)
        if let first = selections.first { view.go(to: first) }
        view.highlightedSelections = []
        // PDFKit finalises page layout after the representable update.
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            guard let view, view.document === document, coordinator.page == page, coordinator.query == query, coordinator.citationID == citation?.id else { return }
            editing?.citationMessage = citation != nil && selections.isEmpty ? "Passage not found on this page." : nil
            view.highlightedSelections = []
            view.setCurrentSelection(nil, animate: false)
            view.needsDisplay = true
        }
    }
    static func selections(on page: PDFPage, query: String) -> [PDFSelection] {
        guard let string = page.string, let terms = try? LibraryIndex.queryTerms(query) else { return [] }
        _ = terms
        var seen = Set<String>()
        return SearchText.matches(string, query: query).compactMap { match in
            guard seen.insert(NSStringFromRange(match.range)).inserted, let selection = page.selection(for: match.range) else { return nil }
            selection.color = HighlightColor.yellow.color.withAlphaComponent(0.45)
            return selection
        }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { (view as? PDFSelectionView)?.selectionActions = PDFSelectionActions(); view.highlightedSelections = []; view.pageOverlayViewProvider = nil; view.document = nil }
}
