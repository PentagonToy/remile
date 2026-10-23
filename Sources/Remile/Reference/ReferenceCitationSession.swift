import Foundation

/// One lazy catalogue snapshot per writing session. Bibliographies reparse only when buffers change.
@MainActor final class ReferenceCitationSession {
    private let context: String
    private let repository: ReferenceRepository
    private var libraryTask: Task<ReferenceCitationIndex, Error>?
    private var projectTask: Task<ReferenceCitationIndex, Never>?
    private var selectedLibrary: UUID?
    private var bibliographySources: [String: String] = [:]
    private var offered: [UUID: ReferenceRecord] = [:]
    private var generation = UUID()
    private(set) var libraryLoads = 0
    private(set) var bibliographyPreparations = 0
    init(context: String, repository: ReferenceRepository = ReferenceRepository()) { self.context = context; self.repository = repository }
    deinit { libraryTask?.cancel(); projectTask?.cancel() }
    func invalidate() { generation = UUID(); libraryTask?.cancel(); libraryTask = nil; selectedLibrary = nil; offered = [:] }
    func release() { invalidate(); projectTask?.cancel(); projectTask = nil; bibliographySources = [:] }
    func completion(source: String, selection: NSRange, buffers: [String: String]) async -> EditorCompletion.Context? {
        guard let prefix = ReferenceCitationCompletion.prefix(source, selection: selection) else { return nil }
        let choice = ReferenceCitationPreferences.read(context)
        if selectedLibrary != choice.library { invalidate(); selectedLibrary = choice.library }
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
                        copy.fields = record.fields.filter { ["title", "author", "year"].contains($0.key) }; copy.originalCitation = ""
                        return copy
                    }
                }
                return ReferenceCitationIndex(records)
            }
        }
        if libraryTask == nil, let library = choice.library {
            let repository = repository; libraryLoads += 1
            libraryTask = Task.detached(priority: .userInitiated) {
                let snapshot = try repository.snapshot(), hidden = Set(snapshot.libraries.filter { $0.trashed != nil }.map(\.id))
                try Task.checkCancellation()
                return ReferenceCitationIndex(snapshot.records.filter {
                    $0.trashed == nil && !hidden.contains($0.library) && $0.collectionID.map(hidden.contains) != true && ($0.library == library || $0.collectionID == library)
                })
            }
        }
        let projectIndex = await projectTask?.value ?? ReferenceCitationIndex()
        let libraryIndex = (try? await libraryTask?.value) ?? ReferenceCitationIndex()
        guard !Task.isCancelled, self.generation == generation else { return nil }
        let suggestions = ReferenceCitationCompletion.suggestions(query: prefix.query, project: projectIndex, library: libraryIndex)
        offered = Dictionary(uniqueKeysWithValues: suggestions.filter { !$0.project }.map { ($0.record.id, $0.record) })
        guard !suggestions.isEmpty else { return nil }
        return EditorCompletion.Context(range: prefix.range, items: suggestions.map {
            .init(label: $0.record.citationKey, insertion: $0.record.citationKey + prefix.closing, referenceID: $0.project ? nil : $0.record.id,
                  detail: $0.record.displayTitle + "\n" + [$0.record.displayAuthors, $0.record.year, $0.project ? "Project" : "Library"].filter { !$0.isEmpty }.joined(separator: " · "))
        })
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
