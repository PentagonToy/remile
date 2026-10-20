import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor final class TeXProject: ObservableObject {
    @Published private(set) var root: URL
    @Published private(set) var files: [String]
    @Published private(set) var treeFiles: [String]
    @Published var selected: String {
        didSet {
            guard oldValue != selected else { return }
            scheduleOutline(); captureHistory(file: oldValue)
            if !navigating { backFiles.append(oldValue); forwardFiles = [] }
        }
    }
    @Published var main: String {
        didSet {
            var choices = UserDefaults.standard.dictionary(forKey: "latex.mainDocuments") as? [String: String] ?? [:]
            choices[root.path] = main; UserDefaults.standard.set(choices, forKey: "latex.mainDocuments")
        }
    }
    @Published var buffers: [String: String] {
        didSet {
            let changed = buffers.keys.filter { buffers[$0] != oldValue[$0] }
            guard !changed.isEmpty else { return }
            if submissionCheck, message != "Source changed · recheck" { message = "Source changed · recheck" }
            for file in changed {
                pendingHistory.insert(file)
                if let ranges = externalEdits[file], !ranges.isEmpty, let before = oldValue[file], let after = buffers[file] { externalEdits[file] = EditorProvenance.rebase(ranges, before: before, after: after) }
            }
            scheduleHistory(); scheduleOutline()
        }
    }
    @Published private(set) var externalEdits: [String: [NSRange]] = [:]
    private var pendingHistory = Set<String>()
    @Published var outline: [TeXOutlineItem] = []
    @Published var setupNeeded = false
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
    private var job: TeXCompileJob?
    private var task: Task<Void, Never>?
    init(_ root: URL) throws {
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
        revisions = TeXHistory.read(self.root); outline = TeXOutlineItem.parse(sources[initial] ?? ""); captureHistory(file: initial)
    }
    var dirty: Bool { buffers != original }
    var source: Binding<String> { Binding(get: { self.buffers[self.selected] ?? "" }, set: { self.buffers[self.selected] = $0 }) }
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
        if TeXConfiguration.current.missingTools(buffers: buffers, submissionCheck: submissionCheck).isEmpty == false { setupNeeded = true; message = "TeX tools are missing."; return }
        self.submissionCheck = submissionCheck
        compileID = UUID(); let id = compileID
        let job = TeXCompileJob { [weak self] output in
            Task { @MainActor [weak self] in guard let self, self.compileID == id, self.compiling else { return }; self.log = output }
        }
        self.job = job; compiling = true; message = nil; log = ""; diagnostics = []
        let root = root, main = main, buffers = buffers, configuration = TeXConfiguration.current
        let destination = output ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/LaTeX/" + UUID().uuidString)
        task = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached { try job.run(root: root, main: main, buffers: buffers, configuration: configuration, output: destination, scratch: scratch, submissionCheck: submissionCheck) }.value
                guard let self else { return }; self.log = result.log; self.diagnostics = TeXDiagnostics.parse(result.log)
                if let data = result.pdf, let document = PDFDocument(data: data) {
                    self.pdf = document; self.message = "\(document.pageCount) pages"
                    if submissionCheck { self.message = self.buffers == buffers && self.main == main ? "Submission check passed" : "Source changed · recheck"; self.showsLog = true }
                    self.build = TeXBuild(pdf: result.output, source: destination.appendingPathComponent("Source"), executable: URL(fileURLWithPath: configuration.directory).appendingPathComponent("synctex"), buffers: buffers, main: main)
                }
                else { self.message = submissionCheck ? "Submission check failed" : "Compilation failed"; self.showsLog = true }
            } catch { self?.message = error is CancellationError ? "Compilation stopped" : error.localizedDescription }
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
            guard let self else { return }; let file = self.selected, source = self.buffers[self.selected] ?? ""
            let outline = await Task.detached { TeXOutlineItem.parse(source) }.value
            guard !Task.isCancelled, self.selected == file, self.buffers[file] == source else { return }; self.outline = outline
        }
    }
    private func scheduleHistory() {
        guard historyTask == nil else { return }
        historyTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(TeXHistory.intervalMinutes * 60)) } catch { return }
            guard let self else { return }; self.historyTask = nil
            let pending = self.pendingHistory
            for file in pending { self.captureHistory(file: file, automatic: true) }
        }
    }
    func captureHistory(file: String, marker: String? = nil, automatic: Bool = false) {
        guard let source = buffers[file] else { return }
        if automatic, let last = revisions.first(where: { $0.file == file }), !TeXHistory.substantial(last.source, source), Date().timeIntervalSince(last.date) < 900 { return }
        pendingHistory.remove(file)
        do { if let revision = try TeXHistory.record(root: root, file: file, source: source, marker: marker, previous: revisions) { revisions.insert(revision, at: 0); revisions = TeXHistory.retained(revisions) } }
        catch { message = "Unable to save local history." }
    }
    func markExternalEdit(file: String, before: String, after: String) {
        let range = EditorProvenance.change(before: before, after: after).inserted
        externalEdits[file] = EditorProvenance.merged((externalEdits[file] ?? []) + (range.length > 0 ? [range] : []))
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
            buffers = Dictionary(uniqueKeysWithValues: buffers.map { (mapped($0.key), $0.value) })
            original = Dictionary(uniqueKeysWithValues: original.map { (mapped($0.key), $0.value) })
            files = files.map(mapped).sorted(); treeFiles = treeFiles.map(mapped).sorted(); main = mapped(main); selected = mapped(selected)
            backFiles = backFiles.map(mapped); forwardFiles = forwardFiles.map(mapped); build = nil
            message = "Moved. TeX references may need updating."
        } catch { message = error.localizedDescription }
    }
    func trash(_ path: String) {
        guard !compiling else { message = "Wait for compilation to finish."; return }
        let affected = files.filter { $0 == path || $0.hasPrefix(path + "/") }
        guard !affected.contains(main) else { message = "Choose another main document before removing this item."; return }
        let alert = NSAlert(); alert.messageText = "Move “\((path as NSString).lastPathComponent)” to Trash?"; alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            for file in affected { captureHistory(file: file) }
            try FileManager.default.trashItem(at: TeXFileSystem.url(path, root: root), resultingItemURL: nil)
            for file in affected { buffers.removeValue(forKey: file); original.removeValue(forKey: file) }
            files.removeAll { affected.contains($0) }; treeFiles.removeAll { $0 == path || $0.hasPrefix(path + "/") }
            if affected.contains(selected) { selected = main }; backFiles.removeAll { affected.contains($0) }; forwardFiles.removeAll { affected.contains($0) }; build = nil
        } catch { message = error.localizedDescription }
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
                    build = nil
                } catch { message = error.localizedDescription }
            }
        }
    }
    @discardableResult func renameProject(to requestedName: String) -> Bool {
        guard !compiling else { return false }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return false }
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
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = root.lastPathComponent + ".zip"
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
        guard build.buffers == buffers, build.main == main else { message = "Compile changes before synchronising."; return nil }
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
                guard self.buffers == build.buffers, self.main == build.main else { self.message = "Compile changes before synchronising."; return }
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
                guard self.buffers == build.buffers, self.main == build.main else { self.message = "Compile changes before synchronising."; return }
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
