import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor final class TeXProject: ObservableObject {
    let identity = UUID()
    lazy var liveWorkspace = OverleafOnlineWorkspace()
    lazy var sourceEditor = MarkdownEditorController()
    var lastPreviewLocation: TeXSync.PDFLocation?
    @Published var overleafReview: OverleafReviewSnapshot?
    @Published var showsAssistant = false
    @Published var canReviewChanges = false
    var decideReviewChange: ((OverleafReviewSnapshot.Change, Bool) async throws -> Void)?
    lazy var citations = ReferenceCitationSession(context: root.path)
    lazy var review = ManuscriptReviewStore.shared(for: root)
    @Published private(set) var isDraft = false
    private var draftDirectory: URL?
    private var draftBaseline: [String: String] = [:]
    var savedDraft: ((URL) -> Void)?
    @Published private(set) var root: URL
    @Published private var connectedName: String?
    @Published private(set) var renamingProject = false
    var renameConnectedProject: ((String) async throws -> Void)?
    var displayName: String { connectedName ?? (isDraft ? "Untitled" : root.lastPathComponent) }
    var connected: Bool { !historyEnabled }
    @Published private(set) var files: [String]
    @Published private(set) var treeFiles: [String]
    @Published var treeFolders: [String] = []
    @Published private(set) var fileRevision = 0
    private var completionIndex: TeXLocalCompletion?
    var localCompletion: TeXLocalCompletion {
        if let completionIndex { return completionIndex }
        let index = TeXLocalCompletion()
        completionIndex = index
        return index
    }
    @Published private(set) var editRevision = 0
    @Published var collections: [TeXCollections.Group] = []
    enum NewItemKind { case file(String), folder(String), collection(UUID?), rename(String), renameCollection(UUID, String) }
    struct NewItemDraft: Identifiable {
        let id = UUID()
        let kind: NewItemKind
        var isRename: Bool { switch kind { case .rename, .renameCollection: return true; default: return false } }
        var placeholder: String { switch kind { case .file: return "File name"; case .folder: return "Folder name"; case .collection: return "Collection name"; case .rename, .renameCollection: return "New name" } }
        var symbol: String { switch kind { case .file: return "doc.text"; case .folder: return "folder"; case .collection, .renameCollection: return "square.stack.3d.up"; case .rename: return "doc.text" } }
        var initialName: String { switch kind { case .rename(let path): return (path as NSString).lastPathComponent; case .renameCollection(_, let name): return name; default: return "" } }
    }
    @Published var newItemDraft: NewItemDraft?
    @Published var newItemError: String?

    @Published var selected: String {
        didSet {
            if !openFiles.contains(selected) { openFiles.append(selected) }
            guard oldValue != selected else { return }
            restoreEditMarks(for: selected)
            refreshSharedEditMarks(for: selected)
            captureHistory(file: oldValue)
            if !navigating { backFiles.append(oldValue); forwardFiles = [] }
        }
    }
    @Published private(set) var openFiles: [String] = []
    @discardableResult func closeSelectedFileTab() -> Bool {
        guard openFiles.count > 1 else { return false }
        closeFileTab(selected); return true
    }
    func cycleFileTab(forward: Bool) {
        guard openFiles.count > 1, let index = openFiles.firstIndex(of: selected) else { return }
        selected = openFiles[(index + (forward ? 1 : openFiles.count - 1)) % openFiles.count]
    }
    func closeFileTab(_ file: String) {
        guard openFiles.count > 1, let index = openFiles.firstIndex(of: file) else { return }
        openFiles.remove(at: index)
        if selected == file { selected = openFiles[min(index, openFiles.count - 1)] }
    }
    func moveFileTab(_ file: String, to target: String, after: Bool) {
        guard file != target, openFiles.contains(file), openFiles.contains(target) else { return }
        var next = openFiles.filter { $0 != file }
        guard let index = next.firstIndex(of: target) else { return }
        next.insert(file, at: index + (after ? 1 : 0)); openFiles = next; selected = file
    }
    @Published var main: String {
        didSet {
            if oldValue != main { outputCurrent = false; scheduleOutline(); if pdf != nil { message = "Edited · recompile" } }
            var choices = UserDefaults.standard.dictionary(forKey: "latex.mainDocuments") as? [String: String] ?? [:]
            choices[root.path] = main; UserDefaults.standard.set(choices, forKey: "latex.mainDocuments")
        }
    }
    @Published private(set) var buffers: [String: String]

    func updateBuffer(_ file: String, to source: String?) {
        let before = buffers[file]
        guard before != source else { return }
        buffers[file] = source
        buffersChanged([file]) { _ in before }
    }

    private func replaceBuffers(with next: [String: String]) {
        let previous = buffers
        let changed = next.keys.filter { next[$0] != previous[$0] } + previous.keys.filter { next[$0] == nil }
        guard !changed.isEmpty else { return }
        buffers = next
        buffersChanged(changed) { previous[$0] }
    }

    private func buffersChanged(_ files: [String], previous: (String) -> String?) {
        editRevision += 1
        if outputCurrent { outputCurrent = false }
        if !compiling, (!log.isEmpty || pdf != nil), message != "Edited · recompile" { message = "Edited · recompile" }
        if submissionCheck, message != "Source changed · recheck" { message = "Source changed · recheck" }
        for file in files {
            bufferHashes.removeValue(forKey: file)
            pendingHistory.insert(file)
            if let after = buffers[file], let before = previous(file) {
                if var tracker = provenance[file] {
                    tracker.transition(before: before, after: after, preserveUnchanged: importingSource)
                    provenance[file] = tracker
                }
                if var tracker = sharedEditRanges[file] {
                    tracker.transition(before: before, after: after, preserveUnchanged: importingSource)
                    sharedEditRanges[file] = tracker
                }
                updateEditRanges(for: file)
            } else if buffers[file] == nil {
                provenance[file] = nil
                sharedEditRanges[file] = nil
                externalEdits[file] = nil
                inspectedEditMarks.remove(file)
            }
        }
        scheduleHistory()
        scheduleOutline()
    }
    @Published private(set) var externalEdits: [String: [NSRange]] = [:]
    private var provenance: [String: EditorProvenance.Tracker] = [:]
    private let editMarkStore: EditorEditMarks.Store
    private let sharedEditMarks: EditorEditMarks.Shared?
    private var sharedEditRanges: [String: EditorProvenance.Tracker] = [:]
    private var inspectedEditMarks = Set<String>()
    private var importingSource = false
    private var pendingHistory = Set<String>()
    @Published var outline: [TeXOutlineItem] = []
    @Published var setupNeeded = false
    @Published var compileFailed = false
    @Published var setupIssue: TeXSetupIssue?
    var editSource: ((String, String, String, String, Bool) -> Bool)?
    private var outlineTask: Task<Void, Never>?
    @Published var revisions: [TeXHistory.Revision] = []
    @Published var showsHistory = false
    @Published private(set) var backFiles: [String] = []
    @Published private(set) var forwardFiles: [String] = []
    var renamedRoot: ((URL, URL) -> Void)?
    private var navigating = false
    private var historyTask: Task<Void, Never>?
    let submission = TeXSubmissionCheck()
    @Published var showsSubmission = false
    @Published var compiling = false
    @Published private(set) var submissionCheck = false
    @Published private(set) var outputCurrent = false
    @Published var log = ""
    @Published var message: String?
    @Published var pdf: PDFDocument?
    @Published var showsLog = false
    @Published var diagnostics: [TeXDiagnostic] = []
    @Published var pdfJump: PDFJump?
    @Published var sourceJump: SourceJump?
    private var diagnosticSource: URL?
    @Published var syncing = false
    struct PDFJump { let id = UUID(); let location: TeXSync.PDFLocation }
    struct SourceJump { enum Highlight { case comment, change }; let id = UUID(); let location: TeXSync.SourceLocation; var marksLine = true; var highlight: Highlight? = nil }
    private(set) var build: TeXBuild?
    private var compileID = UUID()
    private var syncTask: Task<Void, Never>?
    private var original: [String: String]
    private var bufferHashes: [String: String] = [:]
    var cachedSourceHashCount: Int { bufferHashes.count }
    /// Shared by review and CLI readers. Edits invalidate only the files that changed.
    var sourceHashes: [String: String] {
        for (file, source) in buffers where bufferHashes[file] == nil { bufferHashes[file] = SourceDigest.sha256(source) }
        return bufferHashes
    }
    private var cachedBuild: URL?
    private var job: TeXCompileJob?
    private var task: Task<Void, Never>?
    private let historyEnabled: Bool
    init(_ root: URL, historyEnabled: Bool = true, displayName: String? = nil, draft: Bool = false,
         editMarkStore: EditorEditMarks.Store = .local, sharedEditMarks: EditorEditMarks.Shared? = nil) throws {
        self.editMarkStore = editMarkStore
        self.sharedEditMarks = sharedEditMarks
        self.historyEnabled = historyEnabled; connectedName = displayName; isDraft = draft; draftDirectory = draft ? root : nil
        let root = root.standardizedFileURL
        self.root = root
        var sources: [String: String] = [:]
        let (paths, folders) = try TeXFileSystem.snapshot(root) { url, relative, size in
            guard OverleafSourceFiles.source(relative) else { return }
            guard (size ?? 0) <= 4_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: url)
            guard data.count <= 4_000_000, sources.count < 2000, let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadTooLarge) }
            sources[relative] = text
        }
        let saved = (UserDefaults.standard.dictionary(forKey: "latex.mainDocuments") as? [String: String])?[root.path]
        guard let initial = TeXMainDocument.choose(sources: sources, saved: saved) else { throw TeXFileSystem.Failure(errorDescription: "Add a .tex file to open this project.") }
        draftBaseline = draft ? sources : [:]
        treeFiles = paths; files = sources.keys.sorted(); buffers = sources; original = sources; main = initial; selected = initial
        openFiles = [initial]
        treeFolders = folders
        collections = TeXCollections.read(self.root)
        revisions = historyEnabled ? TeXHistory.read(self.root) : []; outline = TeXOutlineItem.project(sources, main: initial); captureHistory(file: initial)
        restoreEditMarks(for: initial)
        refreshSharedEditMarks(for: initial)
    }
    deinit { task?.cancel(); job?.stop(); outlineTask?.cancel(); historyTask?.cancel(); syncTask?.cancel(); TeXCache.discard(cachedBuild); if let draftDirectory { try? FileManager.default.removeItem(at: draftDirectory) } }
    var draftChanged: Bool { isDraft && (buffers != draftBaseline || Set(treeFiles) != Set(draftBaseline.keys) || connectedName != nil) }
    var dirty: Bool { buffers != original || draftChanged }
    /// Live updates touch one known source, with buffer and disk compare-and-swap checks.
    func installLiveSource(_ file: String, expected: String, text: String, expectedDisk: String) throws {
        guard buffers[file] == expected, files.contains(file), treeFiles.contains(file) else { throw OverleafSource.Failure.staleDraft }
        let url = root.appendingPathComponent(file)
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL,
              url.path.hasPrefix(root.path + "/"),
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw OverleafSource.Failure.staleDraft }
        let disk = try String(contentsOf: url, encoding: .utf8)
        guard disk == expectedDisk || disk == expected else { throw OverleafSource.Failure.staleDraft }
        try OverleafSource.validate(text)
        if disk != text { try text.write(to: url, atomically: true, encoding: .utf8) }
        if expected != text {
            importingSource = true
            updateBuffer(file, to: text)
            importingSource = false
        }
        original[file] = text
        saveEditMarks(for: file, text: text)
        if file == selected { refreshSharedEditMarks(for: file) }
    }
    struct LiveFileInstall: Sendable {
        let root: URL
        let editRevision: Int
        let fileRevision: Int
        let expected: [String: Data]
        let result: [String: Data]
        let paths: Set<String>
        let moved: [String: String]
        let matchesRemote: Bool
    }
    /// Build a validated immutable plan off-main. The editor must still match its captured revisions at install.
    nonisolated static func prepareLiveInstall(root: URL, buffers: [String: String], editRevision: Int, fileRevision: Int,
                                               base: [String: Data], result: [String: Data], head: String) throws -> LiveFileInstall {
        let current = try OverleafSourceFiles.scan(root, buffers: buffers)
        guard try OverleafGit.head(root) == head else { throw OverleafGit.Failure("Git history changed during sync. Review changes.") }
        let merged = try OverleafGitSync.reconcile(base: base, current: current, result: result)
        let touched = Set(current.keys).union(merged.keys).filter { current[$0] != merged[$0] }
        return .init(root: root, editRevision: editRevision, fileRevision: fileRevision,
                     expected: current, result: merged, paths: Set(touched),
                     moved: OverleafGitSync.exactSourceRenames(base: current, changed: merged), matchesRemote: merged == result)
    }
    /// Apply only a current plan. Unbuffered files retain an exact final check against external edits.
    func installLiveFiles(_ plan: LiveFileInstall) throws {
        let expected = plan.expected, result = plan.result, paths = plan.paths
        let moved = plan.moved
        let textOnly = paths.allSatisfy { buffers[$0] != nil && result[$0] != nil && OverleafSourceFiles.source($0) }
        guard root.standardizedFileURL.path == plan.root.standardizedFileURL.path, editRevision == plan.editRevision, fileRevision == plan.fileRevision,
              !compiling || textOnly else { throw OverleafSourceFiles.Failure.stale }
        guard !paths.isEmpty else { return }
        for path in paths where buffers[path] == nil || !OverleafSourceFiles.source(path) {
            let url = try TeXFileSystem.url(path, root: root)
            var disk: Data?
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= OverleafSourceFiles.fileLimit else { throw OverleafSourceFiles.Failure.stale }
                disk = try Data(contentsOf: url, options: .mappedIfSafe)
            }
            guard disk == expected[path] else { throw OverleafSourceFiles.Failure.stale }
        }
        for path in paths {
            guard OverleafSourceFiles.validPath(path) else { throw OverleafSourceFiles.Failure.invalid }
            if let bytes = result[path], OverleafSourceFiles.source(path) {
                guard bytes.count <= OverleafSource.textLimit, String(data: bytes, encoding: .utf8) != nil else { throw OverleafSourceFiles.Failure.invalid }
            }
            _ = try TeXFileSystem.url(path, root: root)
        }
        var installed: [String] = []
        do {
            for path in paths.sorted() {
                let url = try TeXFileSystem.url(path, root: root)
                if let bytes = result[path] {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                installed.append(path)
            }
        } catch {
            for path in installed {
                let url = root.appendingPathComponent(path)
                if let bytes = expected[path] { try? bytes.write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
        for (source, destination) in moved where OverleafSourceFiles.source(source) {
            editMarkStore.move(from: root.appendingPathComponent(source), to: root.appendingPathComponent(destination))
            sharedEditMarks?.move(from: source, to: destination)
            sharedEditRanges[destination] = sharedEditRanges[source]
            if let tracker = provenance[source] {
                provenance[destination] = tracker
                inspectedEditMarks.insert(destination)
            }
            updateEditRanges(for: destination)
        }
        importingSource = true
        for path in paths {
            if OverleafSourceFiles.source(path), let bytes = result[path], let text = String(data: bytes, encoding: .utf8) {
                updateBuffer(path, to: text); original[path] = text
                saveEditMarks(for: path, text: text)
            } else {
                updateBuffer(path, to: nil); original[path] = nil; pendingHistory.remove(path)
                if OverleafSourceFiles.source(path), moved[path] == nil {
                    editMarkStore.remove(for: root.appendingPathComponent(path))
                    sharedEditMarks?.remove(path)
                }
            }
        }
        importingSource = false
        (treeFiles, treeFolders) = try TeXFileSystem.snapshot(root)
        let visiblePaths = Set(treeFiles)
        for path in buffers.keys where !visiblePaths.contains(path) {
            updateBuffer(path, to: nil)
            original[path] = nil
        }
        for path in treeFiles where buffers[path] == nil && OverleafSourceFiles.source(path) {
            if let bytes = result[path], let text = String(data: bytes, encoding: .utf8), bytes.count <= OverleafSource.textLimit { updateBuffer(path, to: text); original[path] = text }
        }
        files = buffers.keys.sorted()
        openFiles = openFiles.map { moved[$0] ?? $0 }
        backFiles = backFiles.map { moved[$0] ?? $0 }; forwardFiles = forwardFiles.map { moved[$0] ?? $0 }
        if let destination = moved[main] { main = destination }
        if let destination = moved[selected] {
            navigating = true; selected = destination; navigating = false
        }
        if buffers[main] == nil, let replacement = TeXMainDocument.choose(sources: buffers, saved: nil) { main = replacement }
        if !treeFiles.contains(selected) { selected = main }
        refreshSharedEditMarks(for: selected)
        openFiles.removeAll { !treeFiles.contains($0) }
        build = nil; outputCurrent = false; fileRevision += 1
    }
    var source: Binding<String> {
        Binding(get: { self.buffers[self.selected] ?? "" }, set: { source in
            let file = self.selected
            if self.buffers[file] != nil { self.updateBuffer(file, to: source) }
        })
    }
    /// Reconcile files placed on disk outside the editor while retaining open buffers.
    func refreshFileTree() async throws {
        let root = root, revision = fileRevision, known = Set(buffers.keys)
        let worker = Task.detached(priority: .utility) {
            var candidates = Set<String>()
            var added: [String: String] = [:]
            let (paths, folders) = try TeXFileSystem.snapshot(root) { _, path, size in
                guard !known.contains(path), OverleafSourceFiles.source(path), known.count < 2000,
                      (size ?? Int.max) <= 4_000_000 else { return }
                candidates.insert(path)
            }
            for path in paths where candidates.contains(path) {
                try Task.checkCancellation()
                guard known.count + added.count < 2000 else { break }
                let url = try TeXFileSystem.url(path, root: root)
                if let bytes = try? Data(contentsOf: url), bytes.count <= 4_000_000,
                   let text = String(data: bytes, encoding: .utf8) { added[path] = text }
            }
            return (paths, folders, added)
        }
        let snapshot = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard self.root == root, fileRevision == revision else { return }
        let (paths, folders, added) = snapshot
        let onDisk = Set(paths)
        var next = buffers
        for path in files where path != main && !onDisk.contains(path) && next[path] == original[path] {
            next[path] = nil; original[path] = nil
        }
        for (path, text) in added where next[path] == nil { next[path] = text; original[path] = text }
        let visible = onDisk.union(next.keys).sorted()
        guard visible != treeFiles || folders != treeFolders || next != buffers else { return }
        if visible != treeFiles { treeFiles = visible }
        if folders != treeFolders { treeFolders = folders }
        if next != buffers {
            let sources = next.keys.sorted()
            if files != sources { files = sources }
            replaceBuffers(with: next)
        }
        let available = Set(visible).union(folders)
        if !available.contains(selected) { selected = main }
        openFiles.removeAll { !available.contains($0) }
        backFiles.removeAll { !available.contains($0) }; forwardFiles.removeAll { !available.contains($0) }
        build = nil; outputCurrent = false; fileRevision += 1
    }
    /// Refresh reviewed disk contents without replacing the editor or its document identity.
    func reloadReviewedFiles() throws {
        guard !dirty else { throw TeXFileSystem.Failure(errorDescription: "The source changed during review. Your unsaved edits were kept. Check changes again.") }
        let snapshot = try TeXProject(root, historyEnabled: false, displayName: connectedName, editMarkStore: editMarkStore)
        let selectedBefore = selected
        let trackedChanges = provenance.keys.filter { buffers[$0] != snapshot.buffers[$0] }
        treeFiles = snapshot.treeFiles; treeFolders = snapshot.treeFolders; files = snapshot.files
        importingSource = true
        replaceBuffers(with: snapshot.buffers); original = snapshot.buffers
        importingSource = false
        for file in trackedChanges {
            if let text = buffers[file] { saveEditMarks(for: file, text: text) }
            else { editMarkStore.remove(for: root.appendingPathComponent(file)) }
        }
        refreshSharedEditMarks(for: selected)
        if buffers[main] == nil { main = snapshot.main }
        if !treeFiles.contains(selectedBefore) { selected = main }
        openFiles.removeAll { !treeFiles.contains($0) }
        backFiles.removeAll { !treeFiles.contains($0) }; forwardFiles.removeAll { !treeFiles.contains($0) }
        collections = snapshot.collections; citations.invalidate()
        build = nil; outputCurrent = false; fileRevision += 1
    }
    @discardableResult func save() -> Bool {
        guard isDraft else { return saveWorkingCopy() }
        let panel = NSSavePanel(); panel.title = "Save LaTeX project"; panel.prompt = "Save"
        panel.nameFieldStringValue = displayName; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        return saveDraft(to: destination)
    }
    @discardableResult func saveDraft(to destination: URL) -> Bool {
        guard isDraft, !compiling, !destination.standardizedFileURL.path.hasPrefix(root.path + "/"), saveWorkingCopy() else { return false }
        let old = root
        do {
            try FileManager.default.copyItem(at: old, to: destination)
            do { try review.relocate(to: destination) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
            citations.release(); citations = ReferenceCitationSession(context: destination.path)
            root = destination.standardizedFileURL; isDraft = false; draftDirectory = nil; draftBaseline = [:]; connectedName = nil
            for file in provenance.keys { if let text = original[file] { saveEditMarks(for: file, text: text) } }
            try? FileManager.default.removeItem(at: old)
            savedDraft?(root); message = nil; return true
        } catch { message = "Save failed: " + error.localizedDescription; return false }
    }
    @discardableResult private func saveWorkingCopy() -> Bool {
        do {
            let changed = files.filter { buffers[$0] != original[$0] }
            let staged = try changed.map { file -> (String, String) in
                guard let source = buffers[file] else { throw CocoaError(.fileNoSuchFile) }
                return (file, source)
            }
            for file in changed { captureHistory(file: file) }
            for file in changed { guard try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) == original[file] else { throw CocoaError(.fileWriteFileExists) } }
            for (file, source) in staged {
                try source.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
                original[file] = source
                saveEditMarks(for: file, text: source)
            }
            message = nil; return true
        } catch { message = "Save failed: " + error.localizedDescription; return false }
    }
    func confirmLeaving() -> Bool {
        for file in pendingHistory { captureHistory(file: file) }; historyTask?.cancel(); historyTask = nil
        guard dirty else { syncTask?.cancel(); stop(); discardDraft(); return true }
        let alert = NSAlert(); alert.messageText = "Save LaTeX project changes?"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Don’t Save")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return false }
        if response == .alertFirstButtonReturn && !save() { return false }
        syncTask?.cancel(); stop(); discardDraft(); return true
    }
    private func discardDraft() {
        guard let draftDirectory else { return }
        try? FileManager.default.removeItem(at: draftDirectory); self.draftDirectory = nil
    }
    func compile(output: URL? = nil, scratch: Bool = false, submissionCheck: Bool = false) {
        guard !compiling else { return }
        self.submissionCheck = submissionCheck
        outputCurrent = false
        if !TeXConfiguration.current.missingTools(buffers: buffers, submissionCheck: submissionCheck).isEmpty {
            setupIssue = nil; setupNeeded = false; compileFailed = true; showsLog = submissionCheck || pdf == nil; showsHistory = false
            message = "TeX tools are missing."
            diagnostics = [TeXDiagnostic(id: 0, severity: .error, message: message!, file: nil, line: nil)]
            return
        }
        setupIssue = nil; setupNeeded = false; compileFailed = false
        compileID = UUID(); let id = compileID
        let job = TeXCompileJob { [weak self] output in
            Task { @MainActor [weak self] in guard let self, self.compileID == id, self.compiling else { return }; self.log = output }
        }
        self.job = job; compiling = true; message = nil; log = ""; diagnostics = []
        let root = root, main = main, configuration = TeXConfiguration.current
        let destination = output ?? TeXCache.allocate("LaTeX")
        let managed = output == nil
        diagnosticSource = destination.appendingPathComponent("Source", isDirectory: true)
        task = Task { @MainActor [weak self] in
            var retained = false
            defer { if managed && !retained { TeXCache.discard(destination) } }
            do {
                try await self?.refreshFileTree()
                guard let buffers = self?.buffers, self?.compileID == id else { return }
                let result = try await Task.detached { try job.run(root: root, main: main, buffers: buffers, configuration: configuration, output: destination, scratch: scratch, submissionCheck: submissionCheck) }.value
                guard let self, self.compileID == id else { return }; self.log = result.log; self.diagnostics = TeXDiagnostics.assessed(TeXDiagnostics.parse(result.log), main: main, source: buffers[main] ?? "")
                if let data = result.pdf, let document = PDFDocument(data: data) {
                    self.outputCurrent = self.buffers == buffers && self.main == main
                    self.pdf = document; self.message = self.outputCurrent ? nil : "Edited · recompile"
                    self.compileFailed = !result.success || self.diagnostics.contains { $0.severity == .error }
                    self.showsLog = submissionCheck; self.showsHistory = false
                    if submissionCheck { self.message = self.outputCurrent ? "Submission check passed" : "Source changed · recheck" }
                    TeXCache.discard(self.cachedBuild); self.cachedBuild = managed ? destination : nil; retained = managed
                    self.build = TeXBuild(pdf: result.output, source: destination.appendingPathComponent("Source"), executable: URL(fileURLWithPath: configuration.directory).appendingPathComponent("synctex"), buffers: buffers, main: main)
                }
                else {
                    self.message = submissionCheck ? "Submission check failed" : "Compilation failed"; self.showsLog = submissionCheck || self.pdf == nil
                    self.setupIssue = TeXSetupIssue.detect(result.log); self.setupNeeded = false; self.showsHistory = false; self.compileFailed = true
                }
            } catch {
                if let self, self.compileID == id {
                    self.message = error is CancellationError ? "Compilation stopped" : error.localizedDescription
                    let captured = (try? String(contentsOf: destination.appendingPathComponent("compiler.log"), encoding: .utf8)) ?? ""
                    self.log = String((captured + "\n" + (self.message ?? "Compilation failed")).suffix(150000))
                    self.diagnostics = TeXDiagnostics.assessed(TeXDiagnostics.parse(self.log), main: main, source: buffers[main] ?? "")
                    if !(error is CancellationError) { self.showsLog = submissionCheck || self.pdf == nil; self.setupIssue = TeXSetupIssue.detect(self.log); self.setupNeeded = false; self.showsHistory = false; self.compileFailed = true }
                }
            }
            self?.compiling = false; self?.job = nil
        }
    }
    func compareSubmission(compareEmbedded: Bool = true) {
        guard !compiling else { return }
        showsSubmission = true; compiling = true
        submission.start(root: root, main: main, buffers: buffers, compareEmbedded: compareEmbedded) { [weak self] in self?.compiling = false }
    }
    /// Closing a workspace must release previews even if a presentation temporarily retains its model.
    func releaseWorkspaceResources() {
        releaseEditorAssistance()
        compileID = UUID(); task?.cancel(); job?.stop(); submission.stop()
        outlineTask?.cancel(); historyTask?.cancel(); historyTask = nil; syncTask?.cancel()
        pdf = nil; build = nil; diagnosticSource = nil
        TeXCache.discard(cachedBuild); cachedBuild = nil
        editSource = nil; compiling = false; syncing = false
    }
    func releaseEditorAssistance() {
        sourceEditor.suspend()
        completionIndex = nil
        citations.release()
    }
    func stop() { job?.stop(); submission.stop() }
    func visit(file: String, line: Int = 0) {
        guard buffers[file] != nil else { return }
        selected = file; sourceJump = SourceJump(location: .init(file: file, line: line))
    }
    func goBack() {
        guard let file = backFiles.popLast() else { return }; navigating = true; forwardFiles.append(selected); selected = file; navigating = false
    }
    func goForward() {
        guard let file = forwardFiles.popLast() else { return }; navigating = true; backFiles.append(selected); selected = file; navigating = false
    }
    private func scheduleOutline() {
        outlineTask?.cancel()
        outlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            let main = self.main, sources = self.buffers, revision = self.editRevision
            let worker = Task.detached { TeXOutlineItem.project(sources, main: main) }
            let outline = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, self.main == main, self.editRevision == revision else { return }
            if self.outline != outline { self.outline = outline }
        }
    }
    private func scheduleHistory() {
        if !historyEnabled || isDraft {
            // Keep one pending save while typing, including during Git I/O.
            // A quiet-period debounce could leave a long session only in RAM.
            guard historyTask == nil else { return }
            historyTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(1000)); try Task.checkCancellation() } catch { return }
                guard let self else { return }; self.historyTask = nil
                guard self.dirty else { return }; _ = self.isDraft ? self.saveWorkingCopy() : self.save()
            }
            return
        }
        guard historyTask == nil else { return }
        historyTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(TeXHistory.intervalMinutes * 60)) } catch { return }
            guard let self else { return }; self.historyTask = nil
            let pending = self.pendingHistory
            for file in pending { self.captureHistory(file: file, automatic: true) }
        }
    }
    func captureHistory(file: String, marker: String? = nil, automatic: Bool = false) {
        guard historyEnabled, !isDraft else { pendingHistory.remove(file); return }
        guard let source = buffers[file] else { return }
        if automatic, let last = revisions.first(where: { $0.file == file }), !TeXHistory.substantial(last.source, source), Date().timeIntervalSince(last.date) < 900 { return }
        pendingHistory.remove(file)
        do { if let revision = try TeXHistory.record(root: root, file: file, source: source, marker: marker, previous: revisions) { revisions.insert(revision, at: 0); revisions = TeXHistory.retained(revisions) } }
        catch { message = "Unable to save local history." }
    }
    func markExternalEdit(file: String, before: String, after: String) {
        guard before != after else { return }
        var tracker = provenance[file] ?? EditorProvenance.Tracker()
        tracker.mark(before: before, after: after); provenance[file] = tracker
        updateEditRanges(for: file)
    }
    func editRanges(in file: String) -> [NSRange] {
        restoreEditMarks(for: file)
        refreshSharedEditMarks(for: file)
        return externalEdits[file] ?? []
    }
    private func restoreEditMarks(for file: String) {
        guard !isDraft, provenance[file] == nil, let text = buffers[file], inspectedEditMarks.insert(file).inserted else { return }
        let url = root.appendingPathComponent(file)
        guard let snapshot = editMarkStore.read(for: url) ?? sharedEditMarks?.ownSnapshot(for: file) else { return }
        let ranges = snapshot.restore(in: text)
        provenance[file] = EditorProvenance.Tracker(ranges: ranges)
        updateEditRanges(for: file)
    }
    func refreshSharedEditMarks(for file: String) {
        guard let sharedEditMarks, sharedEditMarks.available, let text = buffers[file], text == original[file] else { return }
        let local = editMarkStore.read(for: root.appendingPathComponent(file))
        if let local, local != sharedEditMarks.ownSnapshot(for: file) { sharedEditMarks.save(local, for: file) }
        let ranges = sharedEditMarks.ranges(fromOtherMacsFor: file, in: text)
        sharedEditRanges[file] = ranges.isEmpty ? nil : EditorProvenance.Tracker(ranges: ranges)
        updateEditRanges(for: file)
    }
    private func updateEditRanges(for file: String) {
        let local = provenance[file]?.ranges ?? []
        let shared = sharedEditRanges[file]?.ranges ?? []
        let ranges = shared.isEmpty ? local : EditorProvenance.merged(local + shared)
        if ranges != externalEdits[file] ?? [] { externalEdits[file] = ranges.isEmpty ? nil : ranges }
    }
    private func saveEditMarks(for file: String, text: String) {
        guard !isDraft, let tracker = provenance[file] else { return }
        let url = root.appendingPathComponent(file)
        if let sharedEditMarks {
            let snapshot = EditorEditMarks.Snapshot(source: text, ranges: tracker.ranges)
            editMarkStore.write(snapshot, for: url)
            sharedEditMarks.save(snapshot, for: file)
        } else { editMarkStore.save(for: url, text: text, ranges: tracker.ranges) }
    }
    func restore(_ revision: TeXHistory.Revision) {
        guard buffers[revision.file] != nil else { message = "The file no longer exists in this project."; return }
        captureHistory(file: revision.file); selected = revision.file; updateBuffer(revision.file, to: revision.source)
        sourceJump = SourceJump(location: .init(file: revision.file, line: 0)); showsHistory = false
    }
    @discardableResult func rename(_ path: String, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { message = "Choose a file name."; return false }
        if name == (path as NSString).lastPathComponent { return true }
        let parent = (path as NSString).deletingLastPathComponent
        let target = parent.isEmpty ? name : parent + "/" + name
        return move(path, to: target)
    }
    @discardableResult func move(_ path: String, to target: String) -> Bool {
        guard !compiling else { message = "Wait for compilation to finish."; return false }
        do {
            captureHistory(file: selected); try TeXFileSystem.move(root: root, from: path, to: target)
            func mapped(_ file: String) -> String { file == path ? target : file.hasPrefix(path + "/") ? target + file.dropFirst(path.count) : file }
            for file in files where mapped(file) != file {
                editMarkStore.move(from: root.appendingPathComponent(file), to: root.appendingPathComponent(mapped(file)))
                sharedEditMarks?.move(from: file, to: mapped(file))
            }
            inspectedEditMarks = Set(inspectedEditMarks.map(mapped))
            sharedEditRanges = Dictionary(uniqueKeysWithValues: sharedEditRanges.map { (mapped($0.key), $0.value) })
            externalEdits = Dictionary(uniqueKeysWithValues: externalEdits.map { (mapped($0.key), $0.value) }); provenance = Dictionary(uniqueKeysWithValues: provenance.map { (mapped($0.key), $0.value) }); pendingHistory = Set(pendingHistory.map(mapped))
            replaceBuffers(with: Dictionary(uniqueKeysWithValues: buffers.map { (mapped($0.key), $0.value) }))
            original = Dictionary(uniqueKeysWithValues: original.map { (mapped($0.key), $0.value) })
            files = files.map(mapped).sorted(); treeFiles = treeFiles.map(mapped).sorted(); treeFolders = treeFolders.map(mapped).sorted(); main = mapped(main); openFiles = openFiles.map(mapped); selected = mapped(selected)
            updateCollections(collections.map { var group = $0; group.paths = group.paths.map(mapped); return group })
            backFiles = backFiles.map(mapped); forwardFiles = forwardFiles.map(mapped); build = nil
            outputCurrent = false; fileRevision += 1
            message = "Check TeX references after moving or renaming a file."
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func trash(_ path: String) { trash([path]) }
    func trash(_ paths: [String]) {
        guard !compiling else { message = "Wait for compilation to finish."; return }
        let paths = TeXFileSystem.topLevel(paths)
        guard !paths.isEmpty else { return }
        let affected = files.filter { file in paths.contains { file == $0 || file.hasPrefix($0 + "/") } }
        guard !affected.contains(main) else { message = "Choose another main document before removing this item."; return }
        let alert = NSAlert(); alert.messageText = paths.count == 1 ? "Move “\((paths[0] as NSString).lastPathComponent)” to Trash?" : "Move \(paths.count) items to Trash?"
        if connected { alert.informativeText = "Also deleted from Overleaf." }
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for path in paths {
            do {
                let removed = files.filter { $0 == path || $0.hasPrefix(path + "/") }
                for file in removed { captureHistory(file: file) }
                try FileManager.default.trashItem(at: TeXFileSystem.url(path, root: root), resultingItemURL: nil)
                for file in removed {
                    updateBuffer(file, to: nil); original.removeValue(forKey: file); pendingHistory.remove(file)
                    editMarkStore.remove(for: root.appendingPathComponent(file))
                    sharedEditMarks?.remove(file)
                }
                files.removeAll { removed.contains($0) }; treeFiles.removeAll { $0 == path || $0.hasPrefix(path + "/") }; treeFolders.removeAll { $0 == path || $0.hasPrefix(path + "/") }
                openFiles.removeAll { $0 == path || $0.hasPrefix(path + "/") }
                if removed.contains(selected) { selected = main }; backFiles.removeAll { removed.contains($0) }; forwardFiles.removeAll { removed.contains($0) }; build = nil; outputCurrent = false; fileRevision += 1
            } catch { message = error.localizedDescription }
        }
    }
    func newFile(in parent: String = "") {
        guard !compiling else { return }
        newItemError = nil; newItemDraft = NewItemDraft(kind: .file(parent))
    }
    func newFolder(in parent: String = "") {
        guard !compiling else { return }
        newItemError = nil; newItemDraft = NewItemDraft(kind: .folder(parent))
    }
    func cancelNewItem() { newItemDraft = nil; newItemError = nil }
    @discardableResult func finishNewItem(_ text: String) -> Bool {
        guard let draft = newItemDraft else { return true }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { cancelNewItem(); return true }
        guard !compiling else { newItemError = "Wait for compilation to finish."; return false }
        do {
            switch draft.kind {
            case .rename(let path):
                guard rename(path, to: name) else { throw TeXFileSystem.Failure(errorDescription: message ?? "Could not rename this item.") }
            case .renameCollection(let id, _):
                guard let index = collections.firstIndex(where: { $0.id == id }) else { throw TeXFileSystem.Failure(errorDescription: "This collection no longer exists.") }
                var groups = collections; groups[index].name = name
                try TeXCollections.write(groups, root: root); collections = groups
            case .file(let parent):
                guard !name.contains("/"), !name.hasPrefix("."), !name.contains("\n"), !name.contains("\r") else { throw TeXFileSystem.Failure(errorDescription: "Choose a file name without slashes, line breaks or a leading dot.") }
                guard files.count < 2000, treeFiles.count < 10000 else { throw CocoaError(.fileWriteOutOfSpace) }
                let path = parent.isEmpty ? name : parent + "/" + name
                let url = try TeXFileSystem.url(path, root: root)
                guard !FileManager.default.fileExists(atPath: url.path) else { throw TeXFileSystem.Failure(errorDescription: "That name already exists.") }
                try Data().write(to: url, options: .withoutOverwriting)
                original[path] = ""; updateBuffer(path, to: ""); files.append(path); files.sort(); treeFiles.append(path); treeFiles.sort()
                fileRevision += 1; visit(file: path)
            case .folder(let parent):
                guard !name.contains("/"), !name.hasPrefix(".") else { throw TeXFileSystem.Failure(errorDescription: "Choose a folder name without slashes or a leading dot.") }
                let path = parent.isEmpty ? name : parent + "/" + name
                let url = try TeXFileSystem.url(path, root: root)
                guard !FileManager.default.fileExists(atPath: url.path) else { throw TeXFileSystem.Failure(errorDescription: "That name already exists.") }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                treeFolders = try TeXFileSystem.folders(root); fileRevision += 1
            case .collection(let parent):
                let groups = collections + [TeXCollections.Group(name: name, parent: parent)]
                try TeXCollections.write(groups, root: root); collections = groups
            }
            cancelNewItem(); return true
        } catch { newItemError = error.localizedDescription; return false }
    }
    func duplicate(_ paths: [String]) {
        guard !compiling, save() else { return }
        for path in TeXFileSystem.topLevel(paths) where treeFiles.contains(path) {
            do {
                let source = try TeXFileSystem.url(path, root: root), base = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
                var number = 1, target: URL
                repeat { target = source.deletingLastPathComponent().appendingPathComponent(base + " copy" + (number == 1 ? "" : " \(number)") + (ext.isEmpty ? "" : "." + ext)); number += 1 } while FileManager.default.fileExists(atPath: target.path)
                try FileManager.default.copyItem(at: source, to: target)
                let added = String(target.path.dropFirst(root.path.count + 1)); treeFiles.append(added); treeFiles.sort()
                if let text = buffers[path] { updateBuffer(added, to: text); original[added] = text; files.append(added); files.sort() }
                outputCurrent = false; fileRevision += 1
            } catch { message = error.localizedDescription }
        }
    }
    func chooseFiles() {
        guard !compiling else { return }
        let panel = NSOpenPanel(); panel.title = "Add files"; panel.prompt = "Add Files"
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let folder = treeFolders.contains(selected) ? selected : (selected as NSString).deletingLastPathComponent
        let urls = panel.urls
        Task { await drop(urls, into: folder) }
    }
    func drop(_ urls: [URL], into folder: String) async {
        guard !compiling, !urls.isEmpty else { return }
        guard urls.count <= 20 else { message = "Add up to 20 items at a time."; return }
        let destinationRoot = root
        for url in urls {
            guard !compiling, root == destinationRoot, !Task.isCancelled else { return }
            let prefix = root.standardizedFileURL.path + "/", local = url.standardizedFileURL.path
            if local.hasPrefix(prefix) {
                let path = String(local.dropFirst(prefix.count)), target = folder.isEmpty ? url.lastPathComponent : folder + "/" + url.lastPathComponent
                if path != target { move(path, to: target) }
            } else {
                do {
                    if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                        try await importFolder(url, into: folder, root: destinationRoot)
                        continue
                    }
                    let path = try TeXFileSystem.importFile(url, root: root, folder: folder)
                    (treeFiles, treeFolders) = try TeXFileSystem.snapshot(root)
                    if ["tex", "bib", "sty", "cls"].contains(url.pathExtension.lowercased()), let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), source.utf8.count <= 4_000_000 {
                        updateBuffer(path, to: source); original[path] = source; files.append(path); files.sort()
                    }
                    build = nil; outputCurrent = false; fileRevision += 1
                } catch { message = error.localizedDescription }
            }
        }
    }
    private func importFolder(_ source: URL, into folder: String, root destinationRoot: URL) async throws {
        let path = folder.isEmpty ? source.lastPathComponent : folder + "/" + source.lastPathComponent
        guard OverleafSourceFiles.validPath(path) else { throw TeXFileSystem.Failure(errorDescription: "Choose a folder with a supported name.") }
        let target = try TeXFileSystem.url(path, root: destinationRoot)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
        let preparation = Task.detached(priority: .userInitiated) { try TeXFileSystem.stageFolder(source, root: destinationRoot) }
        let staged = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { try? FileManager.default.removeItem(at: staged.staging) }
        try Task.checkCancellation()
        guard root == destinationRoot, !compiling, target == (try TeXFileSystem.url(path, root: destinationRoot)) else {
            throw TeXFileSystem.Failure(errorDescription: "The destination changed. Drop the folder again.")
        }
        guard treeFiles.count + staged.files.count <= 10000, treeFolders.count + staged.folders.count < 10000,
              files.count + staged.sources.count <= 2000 else { throw CocoaError(.fileReadTooLarge) }
        try FileManager.default.moveItem(at: staged.staging, to: target)
        let prefix = path + "/"
        treeFiles = (treeFiles + staged.files.map { prefix + $0 }).sorted()
        treeFolders = (treeFolders + [path] + staged.folders.map { prefix + $0 }).sorted()
        for (relative, text) in staged.sources {
            let name = prefix + relative
            updateBuffer(name, to: text); original[name] = text; files.append(name)
        }
        files.sort(); build = nil; outputCurrent = false; fileRevision += 1
    }
    @discardableResult func renameProject(to requestedName: String) -> Bool {
        guard !compiling, !renamingProject else { return false }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        if connected {
            guard name.utf16.count <= 150, name.rangeOfCharacter(from: .controlCharacters) == nil, let renameConnectedProject else { message = "Use an Overleaf project name up to 150 characters."; return false }
            if name == connectedName { return true }
            renamingProject = true; message = "Renaming project…"
            Task { @MainActor [weak self] in
                do { try await renameConnectedProject(name); self?.connectedName = name; self?.message = nil }
                catch { self?.message = "Rename failed: " + error.localizedDescription }
                self?.renamingProject = false
            }
            return true
        }
        guard !name.contains("/"), name != ".", name != ".." else { return false }
        if isDraft { connectedName = name; return true }
        if name == root.lastPathComponent { return true }
        let old = root, target = root.deletingLastPathComponent().appendingPathComponent(name)
        do {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
            captureHistory(file: selected); try FileManager.default.moveItem(at: root, to: target)
            let history = TeXHistory.directory(old), destination = TeXHistory.directory(target)
            if FileManager.default.fileExists(atPath: history.path), !FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.copyItem(at: history, to: destination) }
            do { try review.relocate(to: target) } catch { try? FileManager.default.moveItem(at: target, to: old); throw error }
            for file in files { editMarkStore.move(from: old.appendingPathComponent(file), to: target.appendingPathComponent(file)) }
            root = target; main = String(main); renamedRoot?(old, target); return true
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult func applyTool(file: String, before: String, after: String, name: String, feedback: Bool = true, reveal: Bool = true) -> Bool {
        guard !compiling, buffers[file] == before else { message = "The source changed. Prepare this action again."; return false }
        restoreEditMarks(for: file)
        captureHistory(file: file, marker: "Before · " + name)
        if let editSource {
            guard editSource(file, before, after, name, reveal) else { message = "Finish composing text before applying this action."; return false }
        } else { updateBuffer(file, to: after) }
        captureHistory(file: file, marker: "After · " + name)
        if feedback, UserDefaults.standard.object(forKey: "editor.toolSounds") as? Bool ?? true, let sound = NSSound(named: "Tink") { sound.volume = 0.16; sound.play() }
        return true
    }
    @discardableResult func editBackgroundBuffer(file: String, before: String, after: String, name: String, undo: UndoManager?) -> Bool {
        guard !compiling, buffers[file] == before else { return false }
        guard before != after else { return true }
        updateBuffer(file, to: after)
        if let undo {
            let opensGroup = undo.groupingLevel == 0
            if opensGroup { undo.beginUndoGrouping() }
            undo.registerUndo(withTarget: self) { [weak undo] project in
                _ = project.editBackgroundBuffer(file: file, before: after, after: before, name: name, undo: undo)
            }
            undo.setActionName(name)
            if opensGroup { undo.endUndoGrouping() }
        }
        return true
    }
    /// Additive only. Existing keys and bibliography configuration remain untouched.
    func addReference(_ record: ReferenceRecord, bibliography path: String) throws {
        guard !compiling else { throw ReferenceFailure("Wait for compilation to finish.") }
        guard path.lowercased().hasSuffix(".bib"), buffers[path] != nil || (path == "remile-references.bib" && !treeFiles.contains(where: { $0.lowercased().hasSuffix(".bib") })) else { throw ReferenceFailure("Choose an existing bibliography.") }
        if let before = buffers[path] {
            let after = try ReferenceCitation.appending(record, to: before)
            guard after != before else { return }
            captureHistory(file: path, marker: "Before · Add reference")
            updateBuffer(path, to: after)
            captureHistory(file: path, marker: "After · Add reference")
        } else {
            guard files.count < 2000, treeFiles.count < 10000 else { throw ReferenceFailure("The project has too many files.") }
            let url = try TeXFileSystem.url(path, root: root)
            let source = try ReferenceCitation.appending(record, to: "")
            try Data(source.utf8).write(to: url, options: .withoutOverwriting)
            original[path] = source; updateBuffer(path, to: source)
            files.append(path); files.sort(); treeFiles.append(path); treeFiles.sort(); fileRevision += 1
        }
        message = "Reference added to " + path
    }
    func exportSource() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = displayName + ".zip"
        guard panel.runModal() == .OK, let output = panel.url, !FileManager.default.fileExists(atPath: output.path) else { return }
        let root = root, buffers = buffers
        Task { @MainActor [weak self] in
            do { try await Task.detached { try TeXSourceSnapshot.export(root: root, buffers: buffers, to: output) }.value; self?.message = "Source archive exported." }
            catch { self?.message = error.localizedDescription }
        }
    }
    var canSync: Bool { build != nil && !syncing && !compiling }
    private func currentBuild() -> TeXBuild? {
        guard let build else { message = "Compile to enable source/PDF navigation."; return nil }
        guard build.buffers == buffers, build.main == main else { message = "Recompile to match source and PDF."; return nil }
        return build
    }
    func syncToPDF(line: Int, hint: TeXSync.TextHint? = nil) {
        guard let build = currentBuild(), !syncing else { return }
        let file = selected; syncing = true
        syncTask = Task { @MainActor [weak self] in
            defer { self?.syncing = false }
            do {
                var location = try await Task.detached { try TeXSync.forward(build, file: file, line: line) }.value
                location.hint = hint
                guard let self, !Task.isCancelled, !self.compiling, self.build?.pdf == build.pdf else { return }
                guard self.buffers == build.buffers, self.main == build.main else { self.message = "Recompile to match source and PDF."; return }
                self.message = nil; self.showsLog = false; self.showsHistory = false; self.pdfJump = PDFJump(location: location)
            } catch { self?.message = error.localizedDescription }
        }
    }
    func syncToSource(_ location: TeXSync.PDFLocation) {
        guard let build, !syncing, !compiling else { return }
        syncing = true
        syncTask = Task { @MainActor [weak self] in
            defer { self?.syncing = false }
            do {
                let target = try await Task.detached { let near = try TeXSync.reverse(build, location: location); return TeXSync.refine(near, source: build.buffers[near.file] ?? "", hint: location.hint) }.value
                guard let self, !Task.isCancelled, !self.compiling, self.build?.pdf == build.pdf else { return }
                guard let current = self.buffers[target.file], let previous = build.buffers[target.file] else { return }
                let destination = TeXSync.relocate(target, from: previous, to: current)
                self.message = current == previous ? nil : "Approximate position · PDF is from the previous build."
                self.showsLog = false; self.showsHistory = false
                self.selected = destination.file; self.sourceJump = SourceJump(location: destination, marksLine: destination.range == nil)
            } catch { self?.message = error.localizedDescription }
        }
    }
    func diagnosticLocation(_ diagnostic: TeXDiagnostic, snapshot: URL? = nil, allowFileOnly: Bool = false) -> TeXSync.SourceLocation? {
        guard let path = diagnostic.file, diagnostic.line.map({ $0 > 0 }) ?? allowFileOnly else { return nil }
        let roots = [snapshot, diagnosticSource, build?.source, root].compactMap { $0 }
        for source in roots {
            let base = URL(fileURLWithPath: source.path, isDirectory: true).standardizedFileURL
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : base.appendingPathComponent(path).standardizedFileURL
            let prefix = base.path + "/"
            guard url.path.hasPrefix(prefix) else { continue }
            let file = String(url.path.dropFirst(prefix.count))
            if buffers[file] != nil { return .init(file: file, line: (diagnostic.line ?? 1) - 1) }
        }
        return nil
    }
    func reveal(_ diagnostic: TeXDiagnostic) {
        guard let location = diagnosticLocation(diagnostic, allowFileOnly: true) else { return }
        showsHistory = false
        selected = location.file; sourceJump = SourceJump(location: location, marksLine: diagnostic.line != nil)
    }

    func export() {
        guard let bytes = pdf?.dataRepresentation() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = (main as NSString).deletingPathExtension + ".pdf"
        if panel.runModal() == .OK, let url = panel.url { do { try bytes.write(to: url, options: .atomic) } catch { message = error.localizedDescription } }
    }
}
