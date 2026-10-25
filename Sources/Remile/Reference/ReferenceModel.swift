import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor final class ReferenceModel: ObservableObject {
    @Published private(set) var records: [ReferenceRecord] = [] { didSet { cachedItems = nil } }
    @Published private(set) var libraries: [ReferenceLibrary] = [.primary] { didSet { cachedItems = nil } }
    @Published var selectedLibrary = ReferenceLibrary.primaryID { didSet { cachedItems = nil } }
    @Published var selected: UUID?
    @Published var selectedIDs = Set<UUID>()
    @Published var query = "" { didSet { cachedItems = nil } }
    @Published var showingTrash = false { didSet { cachedItems = nil } }
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var recognising = false
    private var recognitionQueue: [ReferenceRecord] = []
    private var recognitionTask: Task<Void, Never>?
    private var recognitionGeneration = UUID()
    private var networkObserver: NSObjectProtocol?
    private let recognitionLookup: @Sendable (ReferenceRecord) async throws -> ReferenceRecord
    private var reloadRequested = false
    private var pendingEdits: [() -> Void] = []
    private(set) var duplicates: [UUID: [UUID]] = [:]
    private(set) var libraryCounts: [UUID: Int] = [:]
    var readingAttachment: UUID?
    var previewPages: [UUID: Int] = [:]
    var previewAttachments: [UUID: UUID] = [:]
    let repository: ReferenceRepository
    @Published private(set) var sorting = ReferenceSort()
    private var cachedItems: [ReferenceRecord]?
    func sort(by column: ReferenceColumn) { cachedItems = nil; sorting.select(column) }
    private let history = ReferenceRepository.History()
    init(repository: ReferenceRepository = ReferenceRepository(), recognitionLookup: @escaping @Sendable (ReferenceRecord) async throws -> ReferenceRecord = ReferencePaperLookup.metadata) {
        self.repository = repository.recordingHistory(history); self.recognitionLookup = recognitionLookup
        networkObserver = NotificationCenter.default.addObserver(forName: NetworkAccessGate.changed, object: NetworkAccess.gate, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if NetworkAccess.offline { self?.cancelRecognition() } }
        }
    }
    deinit { recognitionTask?.cancel(); if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) } }
    var canUndo: Bool { !busy && history.canUndo }
    var canRedo: Bool { !busy && history.canRedo }
    func undo(redo: Bool = false) { perform { try $0.undo(redo: redo); return nil } }
    var activeLibraries: [ReferenceLibrary] { libraries.filter { $0.trashed == nil } }
    var deletedLibraries: [ReferenceLibrary] { libraries.filter { child in child.trashed != nil && (child.parentID == nil || libraries.first(where: { $0.id == child.parentID })?.trashed == nil) } }
    var trashRecords: [ReferenceRecord] { let ids = Set(libraries.filter { $0.trashed != nil }.map(\.id)); return records.filter { $0.trashed != nil || ids.contains($0.library) || $0.collectionID.map(ids.contains) == true } }
    func contents(_ library: UUID) -> [ReferenceRecord] { let hidden = Set(libraries.filter { $0.trashed != nil }.map(\.id)); return records.filter { ($0.library == library || $0.collectionID == library) && !hidden.contains($0.library) && $0.collectionID.map(hidden.contains) != true } }
    var libraryRecords: [ReferenceRecord] { contents(selectedLibrary) }
    var items: [ReferenceRecord] {
        if let cachedItems { return cachedItems }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = (showingTrash ? trashRecords : libraryRecords.filter { $0.trashed == nil }).filter { text.isEmpty || $0.searchText.localizedCaseInsensitiveContains(text) }
        let result = sorting.sorted(filtered)
        cachedItems = result
        return result
    }
    var selection: ReferenceRecord? { items.first { $0.id == selected } }
    func selectLibrary(_ id: UUID, trash: Bool = false) { selectedLibrary = id; showingTrash = trash; selected = items.first?.id; selectedIDs = Set([selected].compactMap { $0 }) }
    func select(_ id: UUID, extending: Bool, range: Bool) {
        if range, let anchor = selected, let start = items.firstIndex(where: { $0.id == anchor }), let end = items.firstIndex(where: { $0.id == id }) {
            selectedIDs.formUnion(items[min(start, end)...max(start, end)].map(\.id))
        } else if extending {
            if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
        } else { selectedIDs = [id] }
        selected = selectedIDs.contains(id) ? id : items.first { selectedIDs.contains($0.id) }?.id
    }
    func watch() async {
        do {
            try repository.requireStorage()
            try FileManager.default.createDirectory(at: repository.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let changes = try DirectoryChanges(repository.root)
            defer { changes.cancel() }
            for await _ in changes.events {
                guard !Task.isCancelled else { return }
                if busy { reloadRequested = true } else { load() }
            }
        } catch { self.error = error.localizedDescription }
    }
    func title(for url: URL) -> String? { records.first { record in record.attachments.contains { repository.attachmentURL($0).standardizedFileURL == url.standardizedFileURL } }?.title }
    func contextRecords(_ record: ReferenceRecord) -> [ReferenceRecord] { selectedIDs.contains(record.id) ? items.filter { selectedIDs.contains($0.id) } : [record] }
    func selectedDuplicates(_ record: ReferenceRecord) -> [ReferenceRecord]? {
        let chosen = contextRecords(record)
        guard !showingTrash, chosen.count > 1, let first = chosen.first, let group = duplicates[first.id], chosen.allSatisfy({ group.contains($0.id) && $0.trashed == nil }) else { return nil }
        return chosen
    }
    func load() {
        let attachment = readingAttachment; readingAttachment = nil
        perform { if let attachment { try $0.refreshAttachment(attachment) }; return nil }
    }
    func addLibrary(_ name: String, parentID: UUID? = nil, completion: @escaping () -> Void = {}) { perform(completion: { if let last = self.activeLibraries.last { self.selectLibrary(last.id) }; completion() }) { _ = try $0.addLibrary(name, parentID: parentID); return nil } }
    func deleteLibrary(_ library: ReferenceLibrary) { perform { try $0.deleteLibrary(library.id); return nil } }
    func restoreLibrary(_ id: UUID) { perform { try $0.restoreLibrary(id); return nil } }
    func emptyTrash() { perform { try $0.emptyTrash(); return nil } }
    func reorderLibrary(_ id: UUID, before target: UUID) { perform { try $0.reorderLibrary(id, before: target); return nil } }
    func merge(_ snapshots: [ReferenceRecord], preferred: UUID, alignMetadata: Bool, resolvedFields: [String: String]? = nil, completion: @escaping () -> Void) { perform(completion: completion) { try $0.merge(snapshots, preferred: preferred, alignMetadata: alignMetadata, resolvedFields: resolvedFields); return preferred } }
    func attachFetched(_ data: Data, to record: ReferenceRecord, completion: @escaping () -> Void, failure: @escaping () -> Void) {
        perform(completion: completion, failure: failure) { try $0.addFetched(record, pdf: data, libraryID: record.collectionID ?? record.library, attachingTo: record.id, expected: record.revision).id }
    }
    func addFetched(_ record: ReferenceRecord, pdf: Data?, completion: @escaping () -> Void, failure: @escaping () -> Void) {
        let library = selectedLibrary
        perform(completion: completion, failure: failure) { try $0.addFetched(record, pdf: pdf, libraryID: library).id }
    }
    func removeAttachments(_ ids: Set<UUID>, from record: ReferenceRecord, completion: @escaping () -> Void = {}) {
        perform(completion: completion) { try $0.removeAttachments(ids, from: record.id, expected: record.revision).id }
    }
    func importFiles(_ urls: [URL], target: ReferenceRecord? = nil, libraryID: UUID? = nil, matchingExisting: Bool = false) {
        let library = libraryID ?? selectedLibrary
        let receipt = ReferenceRecognition.Receipt()
        perform(completion: { [weak self] in
            Task { @MainActor [weak self] in self?.recognise(await receipt.read().filter(ReferenceRecognition.automaticEligible)) }
        }) { repository in
            let saved = try repository.importFiles(urls, attachingTo: target?.id, expected: target?.revision, libraryID: library, matchingExisting: matchingExisting)
            await receipt.store(saved)
            return saved.first?.id
        }
    }
    func recognise(_ chosen: [ReferenceRecord]) {
        guard !NetworkAccess.offline else { return }
        error = nil
        let queued = Set(recognitionQueue.map(\.id))
        recognitionQueue.append(contentsOf: chosen.filter { ReferenceRecognition.eligible($0) && !queued.contains($0.id) })
        guard recognitionTask == nil, !recognitionQueue.isEmpty else { return }
        recognising = true; recognitionGeneration = UUID()
        let generation = recognitionGeneration, repository = repository, lookup = recognitionLookup
        recognitionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let batch = self?.takeRecognition() ?? []
                guard !batch.isEmpty else { break }
                let receipt = ReferenceRecognition.Receipt()
                _ = await ReferenceRecognition.enrich(batch, repository: repository, lookup: lookup, onFailure: { await receipt.fail($0) })
                if let message = await receipt.failure(), !Task.isCancelled { self?.error = message }
                guard !Task.isCancelled else { break }
                self?.refreshAfterRecognition()
            }
            guard self?.recognitionGeneration == generation else { return }
            self?.recognising = false; self?.recognitionTask = nil
        }
    }
    func cancelRecognition() {
        recognitionGeneration = UUID(); recognitionQueue = []
        recognitionTask?.cancel(); recognitionTask = nil; recognising = false
    }
    private func takeRecognition() -> [ReferenceRecord] {
        let batch = recognitionQueue; recognitionQueue = []; return batch
    }
    private func refreshAfterRecognition() {
        if busy { reloadRequested = true } else { load() }
    }
    func save(_ record: ReferenceRecord, existing: Bool, selectAfterSave: Bool = true, onFailure: @escaping () -> Void = {}, onSaved: @escaping () -> Void = {}) {
        let library = selectedLibrary
        perform(completion: onSaved, failure: onFailure, queueIfBusy: !selectAfterSave, selectResult: selectAfterSave) { repository in
            if existing { return try repository.update(record, expected: record.revision).id }
            return try repository.add([record], libraryID: library).first?.id
        }
    }
    func applyCleanup(_ changes: [ReferenceCleanup.Change], completion: @escaping () -> Void) { perform(completion: completion, selectResult: false) { try $0.applyCleanup(changes); return nil } }
    func regenerate(_ record: ReferenceRecord? = nil) {
        let rule = ReferenceKeyRule.current, library = selectedLibrary
        perform { _ = try $0.regenerate(id: record?.id, expected: record?.revision, libraryID: library, rule: rule); return record?.id }
    }
    func duplicate(_ record: ReferenceRecord, to library: UUID? = nil) { perform { try $0.duplicate(record.id, to: library).id } }
    func move(_ record: ReferenceRecord, to collection: UUID?) { perform { try $0.move(record.id, to: collection); return record.id } }
    func trash(_ record: ReferenceRecord, restore: Bool = false) { perform { try $0.trash(record.id, restore: restore); return nil } }
    func copy(_ record: ReferenceRecord) { copy([record]) }
    func copy(_ chosen: [ReferenceRecord]) {
        do {
            let source = try ReferenceExport.bibtex(chosen)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string)
        } catch { self.error = error.localizedDescription }
    }
    func chooseFiles(target: ReferenceRecord? = nil) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = target == nil ? [.pdf, UTType(filenameExtension: "bib") ?? .plainText, UTType(filenameExtension: "bibtex") ?? .plainText] : [.pdf]
        panel.message = target == nil ? "Add PDF or BibTeX files to Reference." : "Add PDFs to this reference."
        if panel.runModal() == .OK { importFiles(panel.urls, target: target) }
    }
    func export(_ chosen: [ReferenceRecord]) {
        guard !chosen.isEmpty else { return }
        do {
            let source = try ReferenceExport.bibtex(chosen)
            let panel = NSSavePanel(); panel.nameFieldStringValue = "References.bib"; panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
            if panel.runModal() == .OK, let url = panel.url { try Data(source.utf8).write(to: url, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }
    private func perform(completion: @escaping () -> Void = {}, failure: @escaping () -> Void = {}, queueIfBusy: Bool = false, selectResult: Bool = true, _ operation: @escaping @Sendable (ReferenceRepository) async throws -> UUID?) {
        guard !busy else {
            if queueIfBusy { pendingEdits.append { self.perform(completion: completion, failure: failure, queueIfBusy: true, selectResult: selectResult, operation) } }
            return
        }
        busy = true; error = nil
        let repository = repository
        Task {
            defer { busy = false; if !pendingEdits.isEmpty { pendingEdits.removeFirst()() } else if reloadRequested { reloadRequested = false; load() } }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let selection = try await operation(repository)
                    let snapshot = try repository.snapshot()
                    let records = snapshot.records, libraries = snapshot.libraries
                    let hidden = Set(libraries.filter { $0.trashed != nil }.map(\.id))
                    let active = records.filter { !hidden.contains($0.library) && $0.collectionID.map(hidden.contains) != true }
                    var counts: [UUID: Int] = [:]
                    for record in active where record.trashed == nil {
                        counts[record.library, default: 0] += 1
                        if let collection = record.collectionID { counts[collection, default: 0] += 1 }
                    }
                    return (records, libraries, selection, ReferenceDuplicates.lookup(active), counts)
                }.value
                records = result.0; libraries = result.1; duplicates = result.3; libraryCounts = result.4
                if !activeLibraries.contains(where: { $0.id == selectedLibrary }), let first = activeLibraries.first { selectedLibrary = first.id }
                if selectResult, let id = result.2, items.contains(where: { $0.id == id }) { selected = id; selectedIDs = [id] }
                if !items.contains(where: { $0.id == selected }) { selected = items.first?.id }
                selectedIDs.formIntersection(Set(items.map(\.id)))
                if selectedIDs.isEmpty, let selected { selectedIDs.insert(selected) }
                completion()
            } catch { self.error = error.localizedDescription; failure() }
        }
    }
}
