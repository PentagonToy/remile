import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor final class TeXProject: ObservableObject {
    let identity = UUID()
    @Published private(set) var root: URL
    @Published private var connectedName: String?
    @Published private(set) var renamingProject = false
    var renameConnectedProject: ((String) async throws -> Void)?
    var displayName: String { connectedName ?? root.lastPathComponent }
    var connected: Bool { !historyEnabled }
    @Published private(set) var files: [String]
    @Published private(set) var treeFiles: [String]
    @Published var treeFolders: [String] = []
    @Published private(set) var fileRevision = 0
    @Published private(set) var editRevision = 0
    @Published var collections: [TeXCollections.Group] = []
    enum NewItemKind { case file(String), folder(String), collection(UUID?), rename(String), renameCollection(UUID, String) }
    struct NewItemDraft: Identifiable {
        let id = UUID()
        let kind: NewItemKind
        var isCollection: Bool { switch kind { case .collection, .renameCollection: return true; default: return false } }
        var placeholder: String { switch kind { case .file: return "File name.tex"; case .folder: return "Folder name"; case .collection: return "Collection name"; case .rename, .renameCollection: return "New name" } }
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
    @Published var syncing = false
    struct PDFJump { let id = UUID(); let location: TeXSync.PDFLocation }
    struct SourceJump { let id = UUID(); let location: TeXSync.SourceLocation }
    private(set) var build: TeXBuild?
    private var compileID = UUID()
    private var syncTask: Task<Void, Never>?
    private var original: [String: String]
    private var cachedBuild: URL?
    private var job: TeXCompileJob?
    private var task: Task<Void, Never>?
    private let historyEnabled: Bool
    init(_ root: URL, historyEnabled: Bool = true, displayName: String? = nil) throws {
        self.historyEnabled = historyEnabled; connectedName = displayName
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
        let candidates = sources.keys.filter { $0.hasSuffix(".tex") && sources[$0]!.contains("\\documentclass") }.sorted()
        guard let chosen = candidates.contains("main.tex") ? "main.tex" : candidates.first else { throw CocoaError(.fileReadCorruptFile) }
        let saved = (UserDefaults.standard.dictionary(forKey: "latex.mainDocuments") as? [String: String])?[root.standardizedFileURL.path]
        let initial = saved.flatMap { sources[$0] != nil && $0.hasSuffix(".tex") ? $0 : nil } ?? chosen
        treeFiles = paths.sorted(); files = sources.keys.sorted(); buffers = sources; original = sources; main = initial; selected = initial
        treeFolders = try TeXFileSystem.folders(self.root)
        collections = TeXCollections.read(self.root)
        revisions = historyEnabled ? TeXHistory.read(self.root) : []; outline = TeXOutlineItem.project(sources, main: initial); captureHistory(file: initial)
    }
    deinit { TeXCache.discard(cachedBuild) }
    var dirty: Bool { buffers != original }
    var source: Binding<String> { Binding(get: { self.buffers[self.selected] ?? "" }, set: { if self.buffers[self.selected] != nil { self.buffers[self.selected] = $0 } }) }
    @discardableResult func save() -> Bool {
        do {
            let changed = files.filter { buffers[$0] != original[$0] }
            for file in changed { captureHistory(file: file) }
            for file in changed { guard try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) == original[file] else { throw CocoaError(.fileWriteFileExists) } }
            for file in changed { try buffers[file]!.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8); original[file] = buffers[file] }
            message = nil; return true
        } catch { message = "Save failed: " + error.localizedDescription; return false }
    }
    func confirmLeaving() -> Bool {
        for file in pendingHistory { captureHistory(file: file) }; historyTask?.cancel()
        guard dirty else { syncTask?.cancel(); stop(); return true }
        let alert = NSAlert(); alert.messageText = "Save LaTeX project changes?"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Don’t Save")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return false }
        if response == .alertFirstButtonReturn && !save() { return false }
        syncTask?.cancel(); stop(); return true
    }
    func compile(output: URL? = nil, scratch: Bool = false, submissionCheck: Bool = false) {
        guard !compiling else { return }
        if TeXConfiguration.current.missingTools(buffers: buffers, submissionCheck: submissionCheck).isEmpty == false { setupIssue = nil; setupNeeded = true; compileFailed = true; message = "TeX tools are missing."; return }
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
        task = Task { @MainActor [weak self] in
            var retained = false
            defer { if managed && !retained { TeXCache.discard(destination) } }
            do {
                let result = try await Task.detached { try job.run(root: root, main: main, buffers: buffers, configuration: configuration, output: destination, scratch: scratch, submissionCheck: submissionCheck) }.value
                guard let self, self.compileID == id else { return }; self.outputCurrent = false; self.log = result.log; self.diagnostics = TeXDiagnostics.parse(result.log)
                if let data = result.pdf, let document = PDFDocument(data: data) {
                    self.outputCurrent = self.buffers == buffers && self.main == main
                    self.pdf = document; self.message = self.outputCurrent ? nil : "Edited · recompile"
                    if submissionCheck { self.message = self.buffers == buffers && self.main == main ? "Submission check passed" : "Source changed · recheck"; self.showsLog = true }
                    TeXCache.discard(self.cachedBuild); self.cachedBuild = managed ? destination : nil; retained = managed
                    self.build = TeXBuild(pdf: result.output, source: destination.appendingPathComponent("Source"), executable: URL(fileURLWithPath: configuration.directory).appendingPathComponent("synctex"), buffers: buffers, main: main)
                }
                else {
                    self.message = submissionCheck ? "Submission check failed" : "Compilation failed"; self.showsLog = true
                    self.setupIssue = TeXSetupIssue.detect(result.log); self.setupNeeded = true; self.compileFailed = true
                }
            } catch {
                if let self, self.compileID == id {
                    self.message = error is CancellationError ? "Compilation stopped" : error.localizedDescription
                    let captured = (try? String(contentsOf: destination.appendingPathComponent("compiler.log"), encoding: .utf8)) ?? ""
                    self.log = String((captured + "\n" + (self.message ?? "Compilation failed")).suffix(150000))
                    self.diagnostics = TeXDiagnostics.parse(self.log)
                    if !(error is CancellationError) { self.showsLog = true; self.setupIssue = TeXSetupIssue.detect(self.log); self.setupNeeded = true; self.compileFailed = true }
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
        if !historyEnabled {
            historyTask?.cancel()
            historyTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(1000)); try Task.checkCancellation() } catch { return }
                guard let self, self.dirty else { return }; _ = self.save()
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
        guard historyEnabled else { pendingHistory.remove(file); return }
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
                guard ["tex", "bib", "sty", "cls"].contains((name as NSString).pathExtension.lowercased()) else { throw TeXFileSystem.Failure(errorDescription: "Use .tex, .bib, .sty or .cls for a source file.") }
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
    func drop(_ urls: [URL], into folder: String) {
        guard !compiling, !urls.isEmpty, urls.count <= 20 else { return }
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
        if name == root.lastPathComponent { return true }
        let old = root, target = root.deletingLastPathComponent().appendingPathComponent(name)
        do {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
            captureHistory(file: selected); try FileManager.default.moveItem(at: root, to: target)
            let history = TeXHistory.directory(old), destination = TeXHistory.directory(target)
            if FileManager.default.fileExists(atPath: history.path), !FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.copyItem(at: history, to: destination) }
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
    func syncToPDF(line: Int) {
        guard let build = currentBuild(), !syncing else { return }
        let file = selected; syncing = true
        syncTask = Task { @MainActor [weak self] in
            defer { self?.syncing = false }
            do {
                let location = try await Task.detached { try TeXSync.forward(build, file: file, line: line) }.value
                guard let self, !Task.isCancelled, !self.compiling, self.build?.pdf == build.pdf else { return }
                guard self.buffers == build.buffers, self.main == build.main else { self.message = "Recompile to match source and PDF."; return }
                self.showsLog = false; self.pdfJump = PDFJump(location: location)
            } catch { self?.message = error.localizedDescription }
        }
    }
    func syncToSource(_ location: TeXSync.PDFLocation) {
        guard let build = currentBuild(), !syncing else { return }
        syncing = true
        syncTask = Task { @MainActor [weak self] in
            defer { self?.syncing = false }
            do {
                let target = try await Task.detached { try TeXSync.reverse(build, location: location) }.value
                guard let self, !Task.isCancelled, !self.compiling, self.build?.pdf == build.pdf else { return }
                guard self.buffers == build.buffers, self.main == build.main else { self.message = "Recompile to match source and PDF."; return }
                self.selected = target.file; self.sourceJump = SourceJump(location: target)
            } catch { self?.message = error.localizedDescription }
        }
    }
    func reveal(_ diagnostic: TeXDiagnostic) {
        guard let path = diagnostic.file, let line = diagnostic.line else { return }
        let source = build?.source ?? root
        let url = URL(fileURLWithPath: path, relativeTo: source).standardizedFileURL
        let prefix = source.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(prefix) else { return }
        let file = String(url.path.dropFirst(prefix.count)); guard buffers[file] != nil else { return }
        selected = file; sourceJump = SourceJump(location: .init(file: file, line: max(0, line - 1)))
    }
    func export() {
        guard let bytes = pdf?.dataRepresentation() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = (main as NSString).deletingPathExtension + ".pdf"
        if panel.runModal() == .OK, let url = panel.url { do { try bytes.write(to: url, options: .atomic) } catch { message = error.localizedDescription } }
    }
}
