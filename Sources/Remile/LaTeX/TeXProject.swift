import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor final class TeXProject: ObservableObject {
    let identity = UUID()
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
    let localCompletion = TeXLocalCompletion()
    @Published private(set) var editRevision = 0
    @Published var collections: [TeXCollections.Group] = []
    enum NewItemKind { case file(String), folder(String), collection(UUID?), rename(String), renameCollection(UUID, String) }
    struct NewItemDraft: Identifiable {
        let id = UUID()
        let kind: NewItemKind
        var isCollection: Bool { switch kind { case .collection, .renameCollection: return true; default: return false } }
        var placeholder: String { switch kind { case .file: return "File name"; case .folder: return "Folder name"; case .collection: return "Collection name"; case .rename, .renameCollection: return "New name" } }
        var symbol: String { switch kind { case .file: return "doc.text"; case .folder: return "folder"; case .collection, .renameCollection: return "square.stack.3d.up"; case .rename: return "doc.text" } }
        var initialName: String { switch kind { case .rename(let path): return (path as NSString).lastPathComponent; case .renameCollection(_, let name): return name; default: return "" } }
    }
    @Published var newItemDraft: NewItemDraft?
    @Published var newItemError: String?

    @Published var selected: String {
        didSet {
            guard oldValue != selected else { return }
            captureHistory(file: oldValue)
            if !navigating { backFiles.append(oldValue); forwardFiles = [] }
        }
    }
    @Published var main: String {
        didSet {
            if oldValue != main { outputCurrent = false; scheduleOutline(); if pdf != nil { message = "Edited · recompile" } }
            var choices = UserDefaults.standard.dictionary(forKey: "latex.mainDocuments") as? [String: String] ?? [:]
            choices[root.path] = main; UserDefaults.standard.set(choices, forKey: "latex.mainDocuments")
        }
    }
    @Published var buffers: [String: String] {
        didSet {
            let changed = Set(buffers.keys).union(oldValue.keys).filter { buffers[$0] != oldValue[$0] }
            guard !changed.isEmpty else { return }
            editRevision += 1
            outputCurrent = false
            if !compiling && (!log.isEmpty || pdf != nil) { message = "Edited · recompile" }
            if submissionCheck, message != "Source changed · recheck" { message = "Source changed · recheck" }
            for file in changed {
                bufferHashes.removeValue(forKey: file)
                pendingHistory.insert(file)
                if var tracker = provenance[file], let before = oldValue[file], let after = buffers[file] { tracker.transition(before: before, after: after); provenance[file] = tracker; externalEdits[file] = tracker.ranges }
            }
            scheduleHistory(); scheduleOutline()
        }
    }
    @Published private(set) var externalEdits: [String: [NSRange]] = [:]
    private var provenance: [String: EditorProvenance.Tracker] = [:]
    private var pendingHistory = Set<String>()
    @Published var outline: [TeXOutlineItem] = []
    @Published var setupNeeded = false
    @Published var compileFailed = false
    @Published var setupIssue: TeXSetupIssue?
    @Published var renamingFile: String?
    var editSource: ((String, String, String, String) -> Bool)?
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
    struct SourceJump { let id = UUID(); let location: TeXSync.SourceLocation; var marksLine = true }
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
    init(_ root: URL, historyEnabled: Bool = true, displayName: String? = nil, draft: Bool = false) throws {
        self.historyEnabled = historyEnabled; connectedName = displayName; isDraft = draft; draftDirectory = draft ? root : nil
        self.root = root.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        var sources: [String: String] = [:], paths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard paths.count < 10000 else { throw CocoaError(.fileReadTooLarge) }
            paths.append(relative)
            guard ["tex", "bib", "sty", "cls"].contains(url.pathExtension.lowercased()) else { continue }
            guard (values.fileSize ?? 0) <= 4_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: url)
            guard data.count <= 4_000_000, sources.count < 2000, let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadTooLarge) }
            sources[relative] = text
        }
        let saved = (UserDefaults.standard.dictionary(forKey: "latex.mainDocuments") as? [String: String])?[root.standardizedFileURL.path]
        guard let initial = TeXMainDocument.choose(sources: sources, saved: saved) else { throw TeXFileSystem.Failure(errorDescription: "Add a .tex file to open this project.") }
        draftBaseline = draft ? sources : [:]
        treeFiles = paths.sorted(); files = sources.keys.sorted(); buffers = sources; original = sources; main = initial; selected = initial
        treeFolders = try TeXFileSystem.folders(self.root)
        collections = TeXCollections.read(self.root)
        revisions = historyEnabled ? TeXHistory.read(self.root) : []; outline = TeXOutlineItem.project(sources, main: initial); captureHistory(file: initial)
    }
    deinit { task?.cancel(); job?.stop(); outlineTask?.cancel(); historyTask?.cancel(); syncTask?.cancel(); TeXCache.discard(cachedBuild); if let draftDirectory { try? FileManager.default.removeItem(at: draftDirectory) } }
    var draftChanged: Bool { isDraft && (buffers != draftBaseline || Set(treeFiles) != Set(draftBaseline.keys) || connectedName != nil) }
    var dirty: Bool { buffers != original || draftChanged }
    /// Live updates touch one known source, with buffer and disk compare-and-swap checks.
    func installLiveSource(_ file: String, expected: String, text: String, expectedDisk: String) throws {
        guard buffers[file] == expected, files.contains(file), treeFiles.contains(file) else { throw OverleafLive.Failure.staleDraft }
        let url = root.appendingPathComponent(file)
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL,
              url.path.hasPrefix(root.path + "/"),
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw OverleafLive.Failure.staleDraft }
        let disk = try String(contentsOf: url, encoding: .utf8)
        guard disk == expectedDisk || disk == expected else { throw OverleafLive.Failure.staleDraft }
        try OverleafLive.validate(text)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if expected != text { buffers[file] = text }
        original[file] = text
    }
    /// Install only reconciled file changes, preserving edits made while a request was pending.
    func installLiveFiles(expected: [String: Data], result: [String: Data], paths: Set<String>) throws {
        guard !compiling, try OverleafLiveFiles.scan(root, buffers: buffers) == expected else { throw OverleafLiveFiles.Failure.stale }
        for path in paths {
            guard OverleafLiveFiles.validPath(path) else { throw OverleafLiveFiles.Failure.invalid }
            if let bytes = result[path], OverleafLiveFiles.source(path) {
                guard bytes.count <= OverleafLive.textLimit, String(data: bytes, encoding: .utf8) != nil else { throw OverleafLiveFiles.Failure.invalid }
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
        for path in paths {
            if OverleafLiveFiles.source(path), let bytes = result[path], let text = String(data: bytes, encoding: .utf8) { buffers[path] = text; original[path] = text }
            else { buffers[path] = nil; original[path] = nil; externalEdits[path] = nil; provenance[path] = nil; pendingHistory.remove(path) }
        }
        treeFiles = try TeXFileSystem.paths(root); treeFolders = try TeXFileSystem.folders(root)
        for path in buffers.keys where !treeFiles.contains(path) { buffers[path] = nil; original[path] = nil }
        for path in treeFiles where buffers[path] == nil && OverleafLiveFiles.source(path) {
            if let bytes = result[path], let text = String(data: bytes, encoding: .utf8), bytes.count <= OverleafLive.textLimit { buffers[path] = text; original[path] = text }
        }
        files = buffers.keys.sorted()
        if buffers[main] == nil, let replacement = TeXMainDocument.choose(sources: buffers, saved: nil) { main = replacement }
        if !treeFiles.contains(selected) { selected = main }
        build = nil; outputCurrent = false; fileRevision += 1
    }
    var source: Binding<String> { Binding(get: { self.buffers[self.selected] ?? "" }, set: { if self.buffers[self.selected] != nil { self.buffers[self.selected] = $0 } }) }
    /// Refresh reviewed disk contents without replacing the editor or its document identity.
    func reloadReviewedFiles() throws {
        guard !dirty else { throw TeXFileSystem.Failure(errorDescription: "The source changed during review. Your unsaved edits were kept. Check changes again.") }
        let snapshot = try TeXProject(root, historyEnabled: false, displayName: connectedName)
        let selectedBefore = selected
        treeFiles = snapshot.treeFiles; treeFolders = snapshot.treeFolders; files = snapshot.files
        buffers = snapshot.buffers; original = snapshot.buffers
        if buffers[main] == nil { main = snapshot.main }
        if !treeFiles.contains(selectedBefore) { selected = main }
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
            for (file, source) in staged { try source.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8); original[file] = source }
            message = nil; return true
        } catch { message = "Save failed: " + error.localizedDescription; return false }
    }
    func confirmLeaving() -> Bool {
        for file in pendingHistory { captureHistory(file: file) }; historyTask?.cancel()
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
        if !TeXConfiguration.current.missingTools(buffers: buffers, submissionCheck: submissionCheck).isEmpty {
            setupIssue = nil; setupNeeded = false; compileFailed = true; showsLog = true; showsHistory = false
            message = "TeX tools are missing."
            diagnostics = [TeXDiagnostic(id: 0, severity: .error, message: message!, file: nil, line: nil)]
            return
        }
        setupIssue = nil; setupNeeded = false; compileFailed = false
        self.submissionCheck = submissionCheck
        compileID = UUID(); let id = compileID
        let job = TeXCompileJob { [weak self] output in
            Task { @MainActor [weak self] in guard let self, self.compileID == id, self.compiling else { return }; self.log = output }
        }
        self.job = job; outputCurrent = false; compiling = true; message = nil; log = ""; diagnostics = []
        let root = root, main = main, buffers = buffers, configuration = TeXConfiguration.current
        let destination = output ?? TeXCache.allocate("LaTeX")
        let managed = output == nil
        diagnosticSource = destination.appendingPathComponent("Source", isDirectory: true)
        task = Task { @MainActor [weak self] in
            var retained = false
            defer { if managed && !retained { TeXCache.discard(destination) } }
            do {
                let result = try await Task.detached { try job.run(root: root, main: main, buffers: buffers, configuration: configuration, output: destination, scratch: scratch, submissionCheck: submissionCheck) }.value
                guard let self, self.compileID == id else { return }; self.outputCurrent = false; self.log = result.log; self.diagnostics = TeXDiagnostics.assessed(TeXDiagnostics.parse(result.log), main: main, source: buffers[main] ?? "")
                if let data = result.pdf, let document = PDFDocument(data: data) {
                    self.outputCurrent = self.buffers == buffers && self.main == main
                    self.pdf = document; self.message = self.outputCurrent ? nil : "Edited · recompile"
                    self.compileFailed = !result.success || self.diagnostics.contains { $0.severity == .error }
                    self.showsLog = submissionCheck || self.compileFailed; self.showsHistory = false
                    if submissionCheck { self.message = self.buffers == buffers && self.main == main ? "Submission check passed" : "Source changed · recheck"; self.showsLog = true }
                    TeXCache.discard(self.cachedBuild); self.cachedBuild = managed ? destination : nil; retained = managed
                    self.build = TeXBuild(pdf: result.output, source: destination.appendingPathComponent("Source"), executable: URL(fileURLWithPath: configuration.directory).appendingPathComponent("synctex"), buffers: buffers, main: main)
                }
                else {
                    self.message = submissionCheck ? "Submission check failed" : "Compilation failed"; self.showsLog = true
                    self.setupIssue = TeXSetupIssue.detect(result.log); self.setupNeeded = false; self.showsHistory = false; self.compileFailed = true
                }
            } catch {
                if let self, self.compileID == id {
                    self.message = error is CancellationError ? "Compilation stopped" : error.localizedDescription
                    let captured = (try? String(contentsOf: destination.appendingPathComponent("compiler.log"), encoding: .utf8)) ?? ""
                    self.log = String((captured + "\n" + (self.message ?? "Compilation failed")).suffix(150000))
                    self.diagnostics = TeXDiagnostics.assessed(TeXDiagnostics.parse(self.log), main: main, source: buffers[main] ?? "")
                    if !(error is CancellationError) { self.showsLog = true; self.setupIssue = TeXSetupIssue.detect(self.log); self.setupNeeded = false; self.showsHistory = false; self.compileFailed = true }
                }
            }
            self?.compiling = false; self?.job = nil
        }
    }
    func compareSubmission() {
        guard !compiling else { return }
        showsSubmission = true; compiling = true
        submission.start(root: root, main: main, buffers: buffers) { [weak self] in self?.compiling = false }
    }
    /// Closing a workspace must release previews even if a presentation temporarily retains its model.
    func releaseWorkspaceResources() {
        compileID = UUID(); task?.cancel(); job?.stop(); submission.stop()
        outlineTask?.cancel(); historyTask?.cancel(); syncTask?.cancel()
        citations.release(); pdf = nil; build = nil; diagnosticSource = nil
        TeXCache.discard(cachedBuild); cachedBuild = nil
        editSource = nil; compiling = false; syncing = false
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
            guard let self else { return }; let main = self.main, sources = self.buffers
            let outline = await Task.detached { TeXOutlineItem.project(sources, main: main) }.value
            guard !Task.isCancelled, self.main == main, self.buffers == sources else { return }; self.outline = outline
        }
    }
    private func scheduleHistory() {
        if !historyEnabled || isDraft {
            historyTask?.cancel()
            historyTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(1000)); try Task.checkCancellation() } catch { return }
                guard let self, self.dirty else { return }; _ = self.isDraft ? self.saveWorkingCopy() : self.save()
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
        var tracker = provenance[file] ?? EditorProvenance.Tracker(); tracker.mark(before: before, after: after); provenance[file] = tracker; externalEdits[file] = tracker.ranges
    }
    func restore(_ revision: TeXHistory.Revision) {
        guard buffers[revision.file] != nil else { message = "The file no longer exists in this project."; return }
        captureHistory(file: revision.file); selected = revision.file; buffers[revision.file] = revision.source
        sourceJump = SourceJump(location: .init(file: revision.file, line: 0)); showsHistory = false
    }
    @discardableResult func rename(_ path: String, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { message = "Choose a file name."; return false }
        if name == (path as NSString).lastPathComponent { return true }
        let parent = (path as NSString).deletingLastPathComponent
        let target = parent.isEmpty ? name : parent + "/" + name
        move(path, to: target)
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(target).path) && !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }
    func move(_ path: String, to target: String) {
        guard !compiling else { message = "Wait for compilation to finish."; return }
        do {
            captureHistory(file: selected); try TeXFileSystem.move(root: root, from: path, to: target)
            func mapped(_ file: String) -> String { file == path ? target : file.hasPrefix(path + "/") ? target + file.dropFirst(path.count) : file }
            externalEdits = Dictionary(uniqueKeysWithValues: externalEdits.map { (mapped($0.key), $0.value) }); provenance = Dictionary(uniqueKeysWithValues: provenance.map { (mapped($0.key), $0.value) }); pendingHistory = Set(pendingHistory.map(mapped))
            buffers = Dictionary(uniqueKeysWithValues: buffers.map { (mapped($0.key), $0.value) })
            original = Dictionary(uniqueKeysWithValues: original.map { (mapped($0.key), $0.value) })
            files = files.map(mapped).sorted(); treeFiles = treeFiles.map(mapped).sorted(); treeFolders = treeFolders.map(mapped).sorted(); main = mapped(main); selected = mapped(selected)
            updateCollections(collections.map { var group = $0; group.paths = group.paths.map(mapped); return group })
            backFiles = backFiles.map(mapped); forwardFiles = forwardFiles.map(mapped); build = nil
            outputCurrent = false; fileRevision += 1
            message = "Check TeX references after moving or renaming a file."
        } catch { message = error.localizedDescription }
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
                for file in removed { buffers.removeValue(forKey: file); original.removeValue(forKey: file); externalEdits.removeValue(forKey: file); provenance.removeValue(forKey: file); pendingHistory.remove(file) }
                files.removeAll { removed.contains($0) }; treeFiles.removeAll { $0 == path || $0.hasPrefix(path + "/") }; treeFolders.removeAll { $0 == path || $0.hasPrefix(path + "/") }
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
                original[path] = ""; buffers[path] = ""; files.append(path); files.sort(); treeFiles.append(path); treeFiles.sort()
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
                if let text = buffers[path] { buffers[added] = text; original[added] = text; files.append(added); files.sort() }
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
        drop(panel.urls, into: folder)
    }
    func drop(_ urls: [URL], into folder: String) {
        guard !compiling, !urls.isEmpty else { return }
        guard urls.count <= 20 else { message = "Add up to 20 files at a time."; return }
        for url in urls {
            let prefix = root.standardizedFileURL.path + "/", local = url.standardizedFileURL.path
            if local.hasPrefix(prefix) {
                let path = String(local.dropFirst(prefix.count)), target = folder.isEmpty ? url.lastPathComponent : folder + "/" + url.lastPathComponent
                if path != target { move(path, to: target) }
            } else {
                do {
                    let path = try TeXFileSystem.importFile(url, root: root, folder: folder)
                    treeFiles = try TeXFileSystem.paths(root)
                    if ["tex", "bib", "sty", "cls"].contains(url.pathExtension.lowercased()), let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), source.utf8.count <= 4_000_000 {
                        buffers[path] = source; original[path] = source; files.append(path); files.sort()
                    }
                    build = nil; outputCurrent = false; treeFolders = try TeXFileSystem.folders(root); fileRevision += 1
                } catch { message = error.localizedDescription }
            }
        }
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
            root = target; main = String(main); renamedRoot?(old, target); return true
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult func applyTool(file: String, before: String, after: String, name: String, feedback: Bool = true) -> Bool {
        guard !compiling, buffers[file] == before else { message = "The source changed. Prepare this action again."; return false }
        captureHistory(file: file, marker: "Before · " + name)
        if let editSource {
            guard editSource(file, before, after, name) else { message = "Finish composing text before applying this action."; return false }
        } else { buffers[file] = after }
        captureHistory(file: file, marker: "After · " + name)
        if feedback, UserDefaults.standard.object(forKey: "editor.toolSounds") as? Bool ?? true, let sound = NSSound(named: "Tink") { sound.volume = 0.16; sound.play() }
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
            buffers[path] = after
            captureHistory(file: path, marker: "After · Add reference")
        } else {
            guard files.count < 2000, treeFiles.count < 10000 else { throw ReferenceFailure("The project has too many files.") }
            let url = try TeXFileSystem.url(path, root: root)
            let source = try ReferenceCitation.appending(record, to: "")
            try Data(source.utf8).write(to: url, options: .withoutOverwriting)
            original[path] = source; buffers[path] = source
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
        guard let build = currentBuild(), !syncing else { return }
        syncing = true
        syncTask = Task { @MainActor [weak self] in
            defer { self?.syncing = false }
            do {
                let target = try await Task.detached { let near = try TeXSync.reverse(build, location: location); return TeXSync.refine(near, source: build.buffers[near.file] ?? "", hint: location.hint) }.value
                guard let self, !Task.isCancelled, !self.compiling, self.build?.pdf == build.pdf else { return }
                guard self.buffers == build.buffers, self.main == build.main else { self.message = "Recompile to match source and PDF."; return }
                self.message = nil; self.selected = target.file; self.sourceJump = SourceJump(location: target, marksLine: false)
            } catch { self?.message = error.localizedDescription }
        }
    }
    func diagnosticLocation(_ diagnostic: TeXDiagnostic) -> TeXSync.SourceLocation? {
        guard let path = diagnostic.file, let line = diagnostic.line, line > 0 else { return nil }
        let roots = [diagnosticSource, build?.source, root].compactMap { $0 }
        for source in roots {
            let base = URL(fileURLWithPath: source.path, isDirectory: true).standardizedFileURL
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : base.appendingPathComponent(path).standardizedFileURL
            let prefix = base.path + "/"
            guard url.path.hasPrefix(prefix) else { continue }
            let file = String(url.path.dropFirst(prefix.count))
            if buffers[file] != nil { return .init(file: file, line: line - 1) }
        }
        return nil
    }
    func reveal(_ diagnostic: TeXDiagnostic) {
        guard let location = diagnosticLocation(diagnostic) else { return }
        showsHistory = false
        selected = location.file; sourceJump = SourceJump(location: location)
    }

    func export() {
        guard let bytes = pdf?.dataRepresentation() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = (main as NSString).deletingPathExtension + ".pdf"
        if panel.runModal() == .OK, let url = panel.url { do { try bytes.write(to: url, options: .atomic) } catch { message = error.localizedDescription } }
    }
}
