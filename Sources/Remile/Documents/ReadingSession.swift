import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A document lives inside the main window. Navigation never discards unsaved work.
@MainActor
final class ReadingSession: ObservableObject {
    private(set) var identity = UUID()
    @Published var document = ReadingDocument() {
        didSet {
            if case .markdown(let before) = oldValue.content, case .markdown(let after) = document.content, before != after { provenance.transition(before: before, after: after); externalEdits = provenance.ranges }
        }
    }
    @Published private(set) var externalEdits: [NSRange] = []
    private var provenance = EditorProvenance.Tracker()
    weak var pdfSession: PDFSession?
    var pdfInspection: ((Int?, String?, String?) throws -> [String: Any])?
    var commentsExport: (() throws -> PDFCommentExport.Archive)?
    var editSource: ((String, String) async -> Bool)?
    func markExternalEdit(before: String, after: String) { provenance.mark(before: before, after: after); externalEdits = provenance.ranges }
    @Published private(set) var url: URL?
    @Published private(set) var isUntitled = false
    private var original = Data()
    var bytes: Data {
        switch document.content {
        case .pdf(let data): return data
        case .markdown(let text): return Data(text.utf8)
        }
    }
    var dirty: Bool { url != nil && ((isUntitled ? !bytes.isEmpty : bytes != original) || (pdfSession?.hasPendingAnnotations ?? false)) }
    func open(_ destination: URL, data suppliedData: Data? = nil, recordRecent: Bool = true) throws {
        if destination.standardizedFileURL == url?.standardizedFileURL { return }
        let data = try suppliedData ?? Data(contentsOf: destination)
        let content: ReadingDocument.Content
        if destination.pathExtension.lowercased() == "pdf" { content = .pdf(data) }
        else {
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            content = .markdown(text)
        }
        guard confirmLeaving() else { return }
        pdfSession?.protection.finish()
        externalEdits = []; provenance = EditorProvenance.Tracker(); editSource = nil; commentsExport = nil; pdfInspection = nil; pdfSession = nil
        identity = UUID(); document.content = content; original = data; url = destination; isUntitled = false
        if recordRecent { NSDocumentController.shared.noteNewRecentDocumentURL(destination) }
    }
    @discardableResult func newMarkdown() -> Bool {
        guard confirmLeaving() else { return false }
        pdfSession?.protection.finish()
        externalEdits = []; provenance = EditorProvenance.Tracker(); editSource = nil; commentsExport = nil; pdfInspection = nil; pdfSession = nil
        identity = UUID(); document.content = .markdown(""); original = Data(); isUntitled = true
        url = URL(fileURLWithPath: "/remile-untitled-" + UUID().uuidString + "/Untitled.md")
        return true
    }
    func signatureSaveNeedsWarning(_ data: Data) -> Bool {
        guard case .pdf = document.content, data != original else { return false }
        let status = pdfSession?.signatureSaveStatus(for: data)
        if status == .atRisk { return true }
        if status == .preserved { return false }
        guard let source = PDFDocument(data: original), PDFFormPreservation.hasDigitalSignature(source) else { return false }
        return status != .preserved
    }
    func discardPDFChanges() {
        guard case .pdf = document.content else { return }
        pdfSession?.discardChanges(to: original)
        document.content = .pdf(original); objectWillChange.send()
    }
    private enum SignatureSaveChoice { case save, discarded, cancel }
    private func confirmSignatureSave(_ data: Data) -> SignatureSaveChoice {
        guard signatureSaveNeedsWarning(data), pdfSession?.protection.authorised != true else { return .save }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Saving may invalidate the PDF’s signatures"
        alert.informativeText = "These changes could not be verified as signature-preserving."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .save
        case .alertThirdButtonReturn:
            discardPDFChanges(); return .discarded
        default: return .cancel
        }
    }
    private func preparePDFSave() throws {
        if case .pdf = document.content, let pdfSession { document.content = .pdf(try pdfSession.prepareSave()) }
    }
    func saveCopy() {
        do { try preparePDFSave() } catch { NSAlert(error: error).runModal(); return }
        guard confirmSignatureSave(bytes) == .save else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = url?.lastPathComponent ?? "Untitled.md"
        switch document.content {
        case .pdf: panel.allowedContentTypes = [.pdf]
        case .markdown: panel.allowedContentTypes = [.remileMarkdown, .plainText]
        }
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try StorageFileAccess.requireWritable(destination); try bytes.write(to: destination, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
    @discardableResult func save() -> Bool {
        guard let url else { return true }
        do { try StorageFileAccess.requireWritable(url) } catch { NSAlert(error: error).runModal(); return false }
        do { try preparePDFSave() } catch { NSAlert(error: error).runModal(); return false }
        switch confirmSignatureSave(bytes) {
        case .cancel: return false
        case .discarded: return true
        case .save: break
        }
        if isUntitled {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Untitled.md"; panel.allowedContentTypes = [.remileMarkdown]
            guard panel.runModal() == .OK, let destination = panel.url else { return false }
            do { try bytes.write(to: destination, options: .atomic); original = bytes; self.url = destination; isUntitled = false; NSDocumentController.shared.noteNewRecentDocumentURL(destination); return true }
            catch { NSAlert(error: error).runModal(); return false }
        }
        do {
            // Avoid overwriting a document edited in another application.
            guard try Data(contentsOf: url) == original else {
                throw NSError(domain: "Remile", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file changed in another app. Keep this window open and save a copy before replacing it."])
            }
            let data = bytes; try data.write(to: url, options: .atomic); original = data
            pdfSession?.protection.committed()
            objectWillChange.send(); return true
        } catch { NSAlert(error: error).runModal(); return false }
    }
    @discardableResult func confirmLeaving() -> Bool {
        pdfSession?.persistReadingPosition()
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(url?.lastPathComponent ?? "document")”?"
        alert.informativeText = "Your changes will be lost if you do not save them."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    @discardableResult func close() -> Bool {
        guard confirmLeaving() else { return false }
        pdfSession?.protection.finish()
        externalEdits = []; provenance = EditorProvenance.Tracker(); editSource = nil; commentsExport = nil; pdfInspection = nil; pdfSession = nil
        url = nil; original = Data(); document = ReadingDocument(); isUntitled = false; return true
    }
}

struct ReadingShell: View {
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @ObservedObject var home: HomeModel
    @ObservedObject var reader: ReadingSession
    @ObservedObject private var overleaf: OverleafLibrary
    init(home: HomeModel, reader: ReadingSession) { self.home = home; self.reader = reader; self.overleaf = home.overleaf }
    private var markdownActive: Bool {
        guard !overleaf.browsing, home.texProject == nil, reader.url != nil else { return false }
        if case .markdown = reader.document.content { return true }
        return false
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if overleaf.browsing {
                OverleafLibraryWorkspace(library: overleaf, open: home.openTeX, prepareRemoval: { root in
                    if home.texProject?.root == root, !home.closeTeX(retainConnection: false) { return false }
                    home.removeRecent(root); return true
                }).transition(.opacity.combined(with: .offset(x: 16)))
            } else if let project = home.texProject {
                VStack(spacing: 0) {
                    if let connection = overleaf.connection(for: project.root) { OverleafBar(library: overleaf, project: project, connection: connection).id(project.identity) }
                    TeXWorkspace(project: project, close: { home.closeTeX() }, title: overleaf.title(for: project.root), projectTags: overleaf.connection(for: project.root).flatMap { overleaf.tags[$0.id] } ?? [], freeOverleaf: overleaf.connection(for: project.root).map { overleaf.isFreeLimited($0) } ?? false, overleafConnection: overleaf.connection(for: project.root), reviewArchiveChanged: { archive in
                        if let connection = overleaf.connection(for: project.root), archive.projectID == connection.projectID { overleaf.comments[connection.id] = archive }
                    }).id(project.identity)
                }.modifier(RemileNavigationContent()).transition(.opacity.combined(with: .offset(x: 12)))
            } else if let url = reader.url {
                DocumentWorkspace(document: $reader.document, fileURL: url, session: reader)
                    .id(url).transition(.opacity.combined(with: .offset(x: 12)))
                    .navigationTitle((home.references.title(for: url) ?? url.deletingPathExtension().lastPathComponent) + (reader.dirty ? " •" : ""))
                    .toolbar {
                        RemileToolbarItem(placement: .navigation) {
                            WorkspaceBackButton(title: home.page == .reference ? "Return to Reference" : "Return to Home") { reader.close() }
                        }
                        if !markdownActive { RemileToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("Convert to PDF…") { home.presentConversion() }
                                Button("Compress PDF…") { home.presentCompression(!reader.dirty && url.pathExtension.lowercased() == "pdf" ? url : nil) }
                                Button("Combine PDFs…") { home.create(.combine, open: home.open) }
                            } label: { SymbolIcon(systemName: "plus").frame(width: RemileControl.toolHit, height: RemileControl.toolHit) }.remileHelp("Document tools")
                        } }
                    }
            } else if home.opening { Color.clear }
            else { HomeWorkspace(model: home).transition(.opacity) }
        }
        .animation(reduceMotion || !animations ? nil : RemileMotion.navigation, value: reader.url)
        .animation(reduceMotion || !animations ? nil : RemileMotion.navigation, value: overleaf.browsing)
        .animation(reduceMotion || !animations ? nil : RemileMotion.navigation, value: home.texProject?.identity)
        .frame(minWidth: 560, minHeight: 450)
        .overlay { if home.opening { ProgressView("Opening document…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .alert("Unable to open document", isPresented: Binding(get: { reader.url != nil && home.error != nil }, set: { if !$0 { home.error = nil } })) {
            Button("OK") { home.error = nil }
        } message: { Text(home.error ?? "") }
        .toolbar {
            RemileToolbarItem(placement: .automatic) { OfflineModeButton() }
        }
        .toolbarBackground(RemileStyle.background, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(WindowCloseGuard(reader: reader, home: home))
        .onOpenURL { RemileWindows.shared.openExternalDocument($0) }
        .sheet(isPresented: $home.guidePresented) { UserGuide() }
        .sheet(isPresented: $home.convertPresented) { ConvertWorkspace(model: home.conversion) }
        .sheet(isPresented: $home.compressPresented) { CompressWorkspace(model: home.compression) }
        .sheet(isPresented: $home.combinePresented) { CombineWorkspace(model: home.combination, open: home.open) }
        .sheet(isPresented: $overleaf.connectionNoticePresented, onDismiss: overleaf.finishConnectionNotice) {
            OverleafConnectionNotice(agree: { overleaf.respondToConnectionNotice(agree: true) }, disagree: { overleaf.respondToConnectionNotice(agree: false) })
        }
        .sheet(isPresented: $overleaf.presented) { OverleafProjects(library: overleaf, open: home.openTeX, prepareRemoval: { root in
            if home.texProject?.root == root, !home.closeTeX(retainConnection: false) { return false }
            home.removeRecent(root); return true
        }) }
        .sheet(isPresented: Binding(get: { overleaf.review != nil }, set: { if !$0 && !overleaf.busy { overleaf.dismissReview() } })) {
            if let review = overleaf.review { OverleafComparison(library: overleaf, review: review, reload: home.refreshReviewedTeX) }
        }

        .alert("Overleaf", isPresented: Binding(get: { overleaf.error != nil && !overleaf.presented && overleaf.review == nil }, set: { if !$0 { overleaf.error = nil } })) { Button("OK") { overleaf.error = nil } } message: { Text(overleaf.error ?? "") }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            HomeFileDrop.receive(providers) { home.handleDrop($0, target: .open) }; return true
        }
        .alert("Unable to open the dropped file", isPresented: Binding(get: { reader.url != nil && home.error != nil }, set: { if !$0 { home.error = nil } })) {
            Button("OK") { home.error = nil }
        } message: { Text(home.error ?? "") }
    }
}

/// Preserve SwiftUI's window delegate while guarding native close actions.
private struct WindowCloseGuard: NSViewRepresentable {
    let reader: ReadingSession
    let home: HomeModel
    func makeCoordinator() -> Coordinator { Coordinator(reader: reader, home: home) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, window.delegate !== context.coordinator else { return }
            context.coordinator.previous = window.delegate
            context.coordinator.titlebarDrag = TitlebarDrag(window: window)
            window.delegate = context.coordinator
            RemileWindows.shared.register(home, window: window)
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let reader: ReadingSession
        let home: HomeModel
        weak var previous: NSWindowDelegate?
        var titlebarDrag: TitlebarDrag?
        init(reader: ReadingSession, home: HomeModel) { self.reader = reader; self.home = home }
        func windowShouldClose(_ sender: NSWindow) -> Bool { (previous?.windowShouldClose?(sender) ?? true) && home.writer?.confirmLeaving() != false && home.closeTeX(retainConnection: false) && reader.close() }
        func windowDidBecomeKey(_ notification: Notification) {
            if let window = notification.object as? NSWindow { RemileWindows.shared.register(home, window: window) }
            previous?.windowDidBecomeKey?(notification)
        }
        func windowWillClose(_ notification: Notification) {
            titlebarDrag = nil
            if let window = notification.object as? NSWindow { RemileWindows.shared.remove(window) }
            previous?.windowWillClose?(notification)
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector) }
    }
}

/// Window-local documents with one active target for commands and the CLI.
@MainActor
final class RemileWindows: ObservableObject {
    static let shared = RemileWindows()
    @Published private(set) var active: HomeModel?
    var createWindow: (() -> Void)?
    private var entries: [ObjectIdentifier: (NSWindow, HomeModel)] = [:]
    private var pending: [(HomeModel) -> Void] = []
    private var opening = false
    private var externalActivation = false
    private var pdfTabs: [(URL, NSWindow)] = []
    private var preparingPDFTab = false
    private var preparedPDFTab: (url: URL, data: Data, parent: NSWindow)?
    private var pdfTabParents: [ObjectIdentifier: NSWindow] = [:]
    private var pdfGroups: [[ObjectIdentifier]] = []
    var models: [HomeModel] { entries.values.map { $0.1 } }
    func makeHome(recordRecent: Bool = true) -> HomeModel {
        let model = HomeModel()
        if let prepared = preparedPDFTab {
            preparedPDFTab = nil
            do {
                try model.openPreparedDocument(prepared.url, data: prepared.data, recordRecent: recordRecent)
                pdfTabParents[ObjectIdentifier(model)] = prepared.parent
            } catch { model.error = error.localizedDescription }
        }
        if externalActivation {
            let actions = pending; pending = []
            for action in actions { action(model) }
        }
        return model
    }
    private func prepareNextPDFTab() {
        guard !preparingPDFTab, preparedPDFTab == nil, !pdfTabs.isEmpty, createWindow != nil else { return }
        preparingPDFTab = true
        let (url, parent) = pdfTabs.removeFirst()
        Task { @MainActor in
            defer { preparingPDFTab = false; if preparedPDFTab == nil { prepareNextPDFTab() } }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                guard entries[ObjectIdentifier(parent)] != nil else { return }
                preparedPDFTab = (url, data, parent)
                createWindow?()
            } catch { entries[ObjectIdentifier(parent)]?.1.error = error.localizedDescription }
        }
    }
    func register(_ model: HomeModel, window: NSWindow) {
        let isNew = entries[ObjectIdentifier(window)] == nil
        window.animationBehavior = .none
        entries[ObjectIdentifier(window)] = (window, model)
        if window.isKeyWindow || active == nil { active = model }
        opening = false
        let actions = pending; pending = []
        for action in actions { action(model) }
        if externalActivation {
            externalActivation = false
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        if isNew, let parent = pdfTabParents.removeValue(forKey: ObjectIdentifier(model)) {
            let parentID = ObjectIdentifier(parent)
            let windowID = ObjectIdentifier(window)
            if let group = pdfGroups.firstIndex(where: { $0.contains(parentID) }) { pdfGroups[group].append(windowID) }
            else { pdfGroups.append([parentID, windowID]) }
            parent.tabbingMode = .disallowed
            window.tabbingMode = .disallowed
            if window.frame != parent.frame { window.setFrame(parent.frame, display: false) }
            window.orderFront(nil); window.makeKey()
            parent.orderOut(nil)
            active = model
            prepareNextPDFTab()
        }
    }
    struct PDFTab: Identifiable {
        let id: ObjectIdentifier
        let title: String
        let url: URL
        let selected: Bool
    }
    func documentTabs(for reader: ReadingSession) -> [PDFTab] {
        guard let window = entries.values.first(where: { $0.1.reader === reader })?.0 else { return [] }
        let ids = pdfGroups.first(where: { $0.contains(ObjectIdentifier(window)) }) ?? [ObjectIdentifier(window)]
        return ids.compactMap { id in
            guard let home = entries[id]?.1,
                  let url = home.reader.url, url.pathExtension.lowercased() == "pdf" else { return nil }
            return PDFTab(id: id, title: url.deletingPathExtension().lastPathComponent, url: url, selected: home.reader === reader)
        }
    }
    func selectDocumentTab(_ id: ObjectIdentifier) {
        guard let window = entries[id]?.0 else { return }
        window.animationBehavior = .none
        let others = (pdfGroups.first(where: { $0.contains(id) }) ?? [])
            .filter { $0 != id }.compactMap { entries[$0] }.filter { $0.0.isVisible }
        for (other, home) in others {
            home.reader.pdfSession?.persistReadingPosition()
            if window.frame != other.frame { window.setFrame(other.frame, display: false) }
        }
        // Swap the retained surfaces in one flush, without native window expansion.
        window.orderFront(nil); window.makeKey()
        for (other, _) in others { other.animationBehavior = .none; other.orderOut(nil) }
        active = entries[id]?.1
    }
    func closeDocumentTab(_ id: ObjectIdentifier) { entries[id]?.0.performClose(nil) }
    func addDocumentTab(for reader: ReadingSession) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        _ = openDroppedPDFs(panel.urls, for: reader)
    }
    @discardableResult func openDroppedPDFs(_ urls: [URL], for reader: ReadingSession) -> Bool {
        guard !urls.isEmpty, urls.count <= 32, urls.allSatisfy({ $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }),
              let home = entries.values.first(where: { $0.1.reader === reader })?.1 else { return false }
        for url in urls { home.open(url) }
        return true
    }
    /// Tabs reuse independent document, annotation and CLI sessions without reloading PDF data.
    func openPDFTab(_ url: URL, from model: HomeModel) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if let existing = entries.values.first(where: { $0.1.reader.url?.resolvingSymlinksInPath().standardizedFileURL.path == path }) {
            selectDocumentTab(ObjectIdentifier(existing.0))
            return true
        }
        guard case .pdf = model.reader.document.content, model.reader.url != nil,
              let parent = entries.values.first(where: { $0.1 === model })?.0,
              createWindow != nil else { return false }
        pdfTabs.append((url, parent))
        prepareNextPDFTab()
        return true
    }
    /// Finder opens join the frontmost PDF group, even when another workspace is active.
    func openExternalDocument(_ url: URL) {
        externalActivation = true
        NSApp.activate(ignoringOtherApps: true)
        let pdfHome = NSApp.orderedWindows.compactMap { entries[ObjectIdentifier($0)]?.1 }
            .first { $0.reader.url?.pathExtension.lowercased() == "pdf" }
        if url.pathExtension.lowercased() == "pdf", let pdfHome { pdfHome.open(url) }
        else { perform { model in
            model.open(url)
            if let window = self.entries.values.first(where: { $0.1 === model })?.0 {
                self.externalActivation = false
                window.makeKeyAndOrderFront(nil)
            }
        } }
    }
    func tabID(for token: String) -> ObjectIdentifier? {
        entries.keys.first { String(describing: $0) == token }
    }
    func moveDocumentTab(_ id: ObjectIdentifier, to target: ObjectIdentifier, after: Bool) {
        guard id != target, entries[id] != nil, entries[target] != nil else { return }
        objectWillChange.send()
        let sourceGroup = pdfGroups.first(where: { $0.contains(id) }) ?? [id]
        let destination = pdfGroups.first(where: { $0.contains(target) }) ?? [target]
        pdfGroups.removeAll { $0.contains(id) || $0.contains(target) }
        if !destination.contains(id) {
            let remainder = sourceGroup.filter { $0 != id }
            if !remainder.isEmpty { pdfGroups.append(remainder) }
        }
        var reordered = destination.filter { $0 != id }
        guard let index = reordered.firstIndex(of: target) else { return }
        reordered.insert(id, at: index + (after ? 1 : 0))
        pdfGroups.append(reordered)
        if !destination.contains(id), let next = sourceGroup.first(where: { $0 != id }) {
            selectDocumentTab(next)
        }
        selectDocumentTab(id)
    }
    func detachDocumentTab(_ id: ObjectIdentifier, at point: NSPoint) {
        guard let window = entries[id]?.0,
              let groupIndex = pdfGroups.firstIndex(where: { $0.contains(id) }),
              pdfGroups[groupIndex].count > 1 else { return }
        objectWillChange.send()
        pdfGroups[groupIndex].removeAll { $0 == id }
        if let next = pdfGroups[groupIndex].first { selectDocumentTab(next) }
        window.setFrameTopLeftPoint(NSPoint(x: point.x - min(120, window.frame.width / 2), y: point.y + 40))
        window.makeKeyAndOrderFront(nil)
        active = entries[id]?.1
    }
    func remove(_ window: NSWindow) {
        objectWillChange.send()
        let id = ObjectIdentifier(window)
        let removed = entries.removeValue(forKey: id)?.1
        if let index = pdfGroups.firstIndex(where: { $0.contains(id) }) {
            pdfGroups[index].removeAll { $0 == id }
            let remaining = pdfGroups[index]
            if remaining.isEmpty { pdfGroups.remove(at: index) }
            if active === removed, let next = remaining.first { selectDocumentTab(next) }
        }
        if active === removed { active = entries.values.first?.1 }
    }
    func perform(_ action: @escaping (HomeModel) -> Void) {
        if let active { action(active) }
        else { pending.append(action); _ = requestHome() }
    }
    func requestHome() -> HomeModel? {
        if active == nil, !opening, let createWindow { opening = true; createWindow() }
        return active
    }
}
