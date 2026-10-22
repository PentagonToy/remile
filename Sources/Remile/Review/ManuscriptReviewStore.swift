import Foundation
import Combine

@MainActor final class ManuscriptReviewStore: ObservableObject {
    nonisolated static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/Reviews") }
    private final class Weak { weak var value: ManuscriptReviewStore?; init(_ value: ManuscriptReviewStore) { self.value = value } }
    private static var stores: [String: Weak] = [:]
    @Published private(set) var archive: ReviewArchive
    @Published private(set) var running = false
    @Published private(set) var message: String?
    private var root: URL
    private let folder: URL
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var unreadable = false
    var hasSavedData: Bool { !archive.runs.isEmpty || FileManager.default.fileExists(atPath: file.path) }
    static func canonical(_ root: URL) -> URL { root.standardizedFileURL.resolvingSymlinksInPath() }
    static func file(for root: URL, under directory: URL = directory) -> URL { directory.appendingPathComponent(SourceDigest.sha256(canonical(root).path) + ".json") }
    private var file: URL { Self.file(for: root, under: folder) }
    static func shared(for root: URL, directory: URL = directory) -> ManuscriptReviewStore {
        let key = file(for: root, under: directory).path
        if let value = stores[key]?.value { return value }
        let value = ManuscriptReviewStore(root: root, directory: directory); stores = stores.filter { $0.value.value != nil }; stores[key] = Weak(value); return value
    }
    init(root: URL, directory: URL = ManuscriptReviewStore.directory) {
        self.root = Self.canonical(root); folder = directory
        archive = ReviewArchive(root: Self.canonical(root).path)
        do { archive = try Self.read(root: root, directory: directory) }
        catch { unreadable = true; message = "Saved reviews could not be read. Export or recover the archive before clearing it. " + error.localizedDescription }
    }
    static func read(root: URL, directory: URL = directory) throws -> ReviewArchive {
        let file = file(for: root, under: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return ReviewArchive(root: canonical(root).path) }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 8_000_000 else { throw ReviewFailure("Invalid review archive.") }
        let archive = try ReviewArchive.decoder().decode(ReviewArchive.self, from: Data(contentsOf: file))
        guard archive.schemaVersion == 1, archive.root == canonical(root).path, archive.runs.count <= 2000, archive.runs.allSatisfy({ $0.questions.count <= 5 }) else { throw ReviewFailure("Unrecognised review archive.") }
        return archive
    }
    private func save(_ next: ReviewArchive) throws {
        let data = try ReviewArchive.encoder().encode(next)
        guard data.count <= 8_000_000, next.runs.count <= 2000 else { throw ReviewFailure("The review archive is full. Export it before clearing saved questions.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard folder.resolvingSymlinksInPath() == folder.standardizedFileURL else { throw ReviewFailure("Review storage must not be a symbolic link.") }
        if FileManager.default.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ReviewFailure("Review storage must not be a symbolic link.") }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func start(buffers: [String: String], selected: String, engine: AssistantEngine? = nil, provider: String = AIConfiguration.mode.rawValue) throws {
        let engine = engine ?? .selected
        guard !running else { throw ReviewFailure("A review is already running.") }
        guard !unreadable else { throw ReviewFailure(message ?? "Saved reviews could not be read.") }
        let status = engine.status(); guard status.ready else { throw ReviewFailure(status.message) }
        let fullCatalog = try ReviewCatalog.load(), instructions = try ReviewCatalog.instructions()
        let catalog = engine.expandedContext ? fullCatalog : ReviewCatalog(schemaVersion: fullCatalog.schemaVersion, version: fullCatalog.version + "-compact", examples: fullCatalog.examples, criteria: fullCatalog.criteria.filter { ["consistency", "scope", "clarity"].contains($0.id) })
        let context = try ReviewContext.make(buffers: buffers, selected: selected, budget: engine.expandedContext ? 48_000 : 2400)
        let criteriaData = try ReviewArchive.encoder().encode(catalog)
        let criteriaIdentity = catalog.version + ":" + SourceDigest.sha256(String(decoding: criteriaData, as: UTF8.self) + instructions)
        let fingerprint = context.fingerprint(criteria: criteriaIdentity, provider: provider)
        if archive.runs.contains(where: { $0.fingerprint == fingerprint }) { message = "This source version has already been reviewed. Saved questions are below."; return }
        let request = try context.request(catalog: catalog, compact: !engine.expandedContext), token = UUID(); generation = token; running = true; message = nil
        task = Task { [self] in
            do {
                let response = try await engine.respond(request, instructions, engine.expandedContext ? 3200 : 900)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let questions = try context.questions(from: response, catalog: catalog)
                let scope = selected + ((context.truncated.isEmpty && context.omittedFiles == 0) ? " · supplied project context" : " · partial project context")
                let run = ReviewRun(id: UUID(), createdAt: Date(), criteriaVersion: catalog.version, provider: provider, fingerprint: fingerprint, sourceHashes: context.sourceHashes, scope: scope, omittedFiles: context.omittedFiles, questions: questions)
                var next = self.archive; next.runs.append(run)
                try self.save(next); self.archive = next
                self.message = nil
            } catch {
                guard self.generation == token else { return }
                self.message = error is CancellationError ? "Review stopped. Saved questions are kept." : error.localizedDescription
            }
            guard self.generation == token else { return }
            self.running = false; self.task = nil
        }
    }
    func stop() { let wasRunning = running; generation = UUID(); task?.cancel(); task = nil; running = false; if wasRunning { message = "Review stopped. Saved questions are kept." } }
    func clear() throws {
        // Cancel first so a late model response cannot restore a cleared archive.
        stop()
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
        archive = ReviewArchive(root: root.path); unreadable = false; message = nil
    }
    static func remove(root: URL, directory: URL = directory) throws {
        let key = file(for: root, under: directory).path
        if let store = stores[key]?.value { try store.clear() }
        else if FileManager.default.fileExists(atPath: key) { try FileManager.default.trashItem(at: URL(fileURLWithPath: key), resultingItemURL: nil) }
    }
    static func removeLibraryFolder(_ root: URL, directory: URL = directory) throws {
        let parent = canonical(root).path
        for (_, weak) in stores where weak.value?.root.path == parent || weak.value?.root.path.hasPrefix(parent + "/") == true { try weak.value?.clear() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000,
                  let archive = try? ReviewArchive.decoder().decode(ReviewArchive.self, from: Data(contentsOf: file)), archive.root == parent || archive.root.hasPrefix(parent + "/") else { continue }
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }
    func relocate(to destination: URL) throws {
        guard !unreadable else { throw ReviewFailure("Recover or clear the unreadable review archive before renaming this project.") }
        stop(); let oldRoot = root, oldFile = file
        root = Self.canonical(destination)
        let newFile = file
        guard oldFile != newFile else { return }
        guard !FileManager.default.fileExists(atPath: newFile.path) else { root = oldRoot; throw ReviewFailure("The destination already has saved reviews.") }
        var next = archive; next.root = root.path
        do { if hasSavedData || !next.runs.isEmpty { try save(next) } }
        catch { root = oldRoot; throw error }
        archive = next
        if FileManager.default.fileExists(atPath: oldFile.path) { try? FileManager.default.trashItem(at: oldFile, resultingItemURL: nil) }
        Self.stores.removeValue(forKey: oldFile.path); Self.stores[newFile.path] = Weak(self)
    }
    func response(format: PDFCommentExport.Format, output: String?) throws -> [String: Any] {
        guard !unreadable else { throw ReviewFailure(message ?? "Saved reviews could not be read.") }
        var value = try archive.response(format: format, output: output)
        value["running"] = running; value["message"] = message ?? ""; return value
    }
}
