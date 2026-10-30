import Foundation

/// One lazy catalogue snapshot per writing session. Bibliographies reparse only when buffers change.
@MainActor final class ReferenceCitationSession {
    private let context: String
    private let repository: ReferenceRepository
    private var libraryTask: Task<ReferenceCitationIndex, Error>?
    private var projectTask: Task<ReferenceCitationIndex, Never>?
    private var selectedLibraries = Set<UUID>()
    private var externalVersion = ""
    private var libraryVersion: ReferenceRepository.Version?
    private var bibliographySources: [String: String] = [:]
    private var offered: [UUID: ReferenceRecord] = [:]
    private var generation = UUID()
    private(set) var libraryLoads = 0
    private(set) var bibliographyPreparations = 0
    init(context: String, repository: ReferenceRepository = ReferenceRepository()) { self.context = context; self.repository = repository }
    deinit { libraryTask?.cancel(); projectTask?.cancel() }
    func invalidate() { generation = UUID(); libraryTask?.cancel(); libraryTask = nil; selectedLibraries = []; libraryVersion = nil; offered = [:] }
    func release() { invalidate(); projectTask?.cancel(); projectTask = nil; bibliographySources = [:] }
    func completion(source: String, selection: NSRange, buffers: [String: String]) async -> EditorCompletion.Context? {
        guard let prefix = ReferenceCitationCompletion.prefix(source, selection: selection) else { return nil }
        let choice = ReferenceCitationPreferences.read(context)
        let repository = repository
        let libraries = choice.selectedLibraries
        let version = libraries.isEmpty ? nil : await Task.detached(priority: .userInitiated) { repository.version() }.value
        guard !Task.isCancelled else { return nil }
        let external = ZoteroCitationSources.signature
        if selectedLibraries != libraries || libraryVersion != version || externalVersion != external {
            invalidate(); selectedLibraries = libraries; libraryVersion = version; externalVersion = external
        }
        let generation = generation
        let sources = buffers.filter { $0.key.lowercased().hasSuffix(".bib") }
        if projectTask == nil || sources != bibliographySources {
            projectTask?.cancel(); bibliographySources = sources; bibliographyPreparations += 1
            projectTask = Task.detached(priority: .userInitiated) {
                var records: [ReferenceRecord] = []
                for path in sources.keys.sorted() {
                    guard !Task.isCancelled else { return ReferenceCitationIndex() }
                    records += ((try? ReferenceBibTeX.parse(sources[path]!)) ?? []).map { record in
                        var copy = record
                        copy.fields = record.fields.filter { ["title", "author", "editor", "year", "abstract", "doi", "eprint", "url", "zoterosource", "zoterolibrary", "zoterocollection"].contains($0.key) }; copy.originalCitation = ""
                        return copy
                    }
                }
                return ReferenceCitationIndex(records)
            }
        }
        if libraryTask == nil, !libraries.isEmpty {
            let repository = repository; libraryLoads += 1
            libraryTask = Task.detached(priority: .userInitiated) {
                let snapshot = try repository.snapshot(), hidden = Set(snapshot.libraries.filter { $0.trashed != nil }.map(\.id))
                try Task.checkCancellation()
                let connected = Set(ZoteroCitationSources.libraries.map(\.id))
                let external: [ReferenceRecord]
                if libraries.isDisjoint(with: connected) { external = [] }
                else { external = (try? await ZoteroCitationSources.shared.records()) ?? [] }
                return ReferenceCitationIndex((snapshot.records + external).filter {
                    $0.trashed == nil && !hidden.contains($0.library) && $0.collectionID.map(hidden.contains) != true && ReferenceCitationPreferences.includes($0, libraries: libraries)
                })
            }
        }
        let projectIndex = await projectTask?.value ?? ReferenceCitationIndex()
        let libraryIndex = (try? await libraryTask?.value) ?? ReferenceCitationIndex()
        guard !Task.isCancelled, self.generation == generation else { return nil }
        let sentence = ReferenceRelevance.sentence(source, before: selection.location)
        let ranking = Task.detached(priority: .userInitiated) {
            ReferenceCitationCompletion.suggestions(query: prefix.query, project: projectIndex, library: libraryIndex, context: sentence)
        }
        let suggestions = await withTaskCancellationHandler { await ranking.value } onCancel: { ranking.cancel() }
        guard !Task.isCancelled, self.generation == generation else { return nil }
        offered = Dictionary(uniqueKeysWithValues: suggestions.filter { !$0.project }.map { ($0.record.id, $0.record) })
        guard !suggestions.isEmpty else { return nil }
        let items: [EditorCompletion.Item] = suggestions.map { suggestion in
            let record = suggestion.record
            let origin = ZoteroCitationSources.origin(record)
            let location = origin ?? (suggestion.project ? "Project" : "Library")
            let summary = [record.displayContributors, record.year, location].filter { !$0.isEmpty }.joined(separator: " · ")
            var details: [String] = []
            if let origin { details.append(origin) }
            details.append(record.displayTitle); details.append(summary)
            if let relevance = suggestion.relevance {
                let intents = relevance.intents.map(\.title).joined(separator: " / ")
                details.append(relevance.basis + " · " + intents + "\n" + relevance.note)
                if !relevance.excerpt.isEmpty { details.append(relevance.excerpt) }
            }
            let annotation: String?
            if origin != nil { annotation = suggestion.project ? "Project · Zotero" : "Zotero" }
            else { annotation = suggestion.relevance?.label }
            return EditorCompletion.Item(label: record.citationKey, insertion: record.citationKey + prefix.closing,
                referenceID: suggestion.project ? nil : record.id, detail: details.joined(separator: "\n"), annotation: annotation)
        }
        return EditorCompletion.Context(range: prefix.range, items: items)
    }
    func prepare(_ item: EditorCompletion.Item, project: TeXProject) throws {
        guard let id = item.referenceID else { return }
        guard let record = offered[id] else { throw ReferenceFailure("Open citation suggestions again.") }
        let preferred = ReferenceCitationPreferences.read(context).bibliography
        let files = project.buffers.keys.filter { $0.lowercased().hasSuffix(".bib") }.sorted()
        guard let destination = ReferenceCitationPreferences.destination(files, preferred: preferred) else { throw ReferenceFailure("Choose a bibliography with the Reference button first.") }
        try project.addReference(record, bibliography: destination)
    }
}
