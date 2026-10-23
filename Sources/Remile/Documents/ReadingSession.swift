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
        do { try bytes.write(to: destination, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
    @discardableResult func save() -> Bool {
        guard let url else { return true }
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
                    if home.texProject?.root == root, !home.closeTeX() { return false }
                    home.removeRecent(root); return true
                })
            } else if let project = home.texProject {
                VStack(spacing: 0) {
                    if let connection = overleaf.connection(for: project.root) { OverleafBar(library: overleaf, project: project, connection: connection).id(project.identity) }
                    TeXWorkspace(project: project, close: { home.closeTeX() }, title: overleaf.title(for: project.root), projectTags: overleaf.connection(for: project.root).flatMap { overleaf.tags[$0.id] } ?? [], freeOverleaf: overleaf.connection(for: project.root).map { overleaf.isFreeLimited($0) } ?? false).id(project.identity)
                }
            } else if let url = reader.url {
                DocumentWorkspace(document: $reader.document, fileURL: url, session: reader)
                    .id(url).transition(.opacity.combined(with: .offset(x: 12)))
                    .navigationTitle((home.references.title(for: url) ?? url.deletingPathExtension().lastPathComponent) + (reader.dirty ? " •" : ""))
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button { reader.close() } label: { Label(home.page == .reference ? "Reference" : "Home", systemImage: "chevron.left") }.remileHelp(home.page == .reference ? "Return to Reference" : "Return to Home")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            if case .markdown = reader.document.content {
                                Button { NotificationCenter.default.post(name: Notification.Name("remile.exportMarkdownPDF"), object: reader) } label: { Image(systemName: "square.and.arrow.up").frame(width: 30, height: 30) }.remileHelp("Export PDF…")
                            } else { Menu {
                                Button("Convert to PDF…") { home.presentConversion() }
                                Button("Compress PDF…") { home.presentCompression(!reader.dirty && url.pathExtension.lowercased() == "pdf" ? url : nil) }
                                Button("Combine PDFs…") { home.create(.combine, open: home.open) }
                            } label: { Image(systemName: "plus").frame(width: 30, height: 30) }.remileHelp("Document tools") }
                        }
                    }
            } else { HomeWorkspace(model: home).transition(.opacity) }
        }
        .animation(reduceMotion ? nil : RemileMotion.navigation, value: reader.url)
        .frame(minWidth: 560, minHeight: 450)
        .overlay { if home.opening { ProgressView("Opening document…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .toolbar {
            if !markdownActive { ToolbarItem(placement: .automatic) { OfflineModeButton() } }
        }
        .toolbarBackground(RemileStyle.background, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(WindowCloseGuard(reader: reader, home: home))
        .onOpenURL { home.open($0) }
        .sheet(isPresented: $home.guidePresented) { UserGuide() }
        .sheet(isPresented: $home.convertPresented) { ConvertWorkspace(model: home.conversion) }
        .sheet(isPresented: $home.compressPresented) { CompressWorkspace(model: home.compression) }
        .sheet(isPresented: $home.combinePresented) { CombineWorkspace(model: home.combination, open: home.open) }
        .sheet(isPresented: $overleaf.presented) { OverleafProjects(library: overleaf, open: home.openTeX, prepareRemoval: { root in
            if home.texProject?.root == root, !home.closeTeX() { return false }
            home.removeRecent(root); return true
        }) }
        .sheet(isPresented: Binding(get: { overleaf.review != nil }, set: { if !$0 && !overleaf.busy { overleaf.dismissReview() } })) {
            if let review = overleaf.review { OverleafComparison(library: overleaf, review: review, reload: home.openTeX) }
        }
        .sheet(isPresented: Binding(get: { overleaf.commentsProject != nil }, set: { if !$0 { overleaf.commentsProject = nil } })) {
            if let project = overleaf.commentsProject { OverleafComments(library: overleaf, connection: project, close: { overleaf.commentsProject = nil }) }
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
        func windowShouldClose(_ sender: NSWindow) -> Bool { (previous?.windowShouldClose?(sender) ?? true) && home.closeTeX() && reader.close() }
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
    var models: [HomeModel] { entries.values.map { $0.1 } }
    func register(_ model: HomeModel, window: NSWindow) {
        entries[ObjectIdentifier(window)] = (window, model)
        if window.isKeyWindow || active == nil { active = model }
        opening = false
        let actions = pending; pending = []
        for action in actions { action(model) }
    }
    func remove(_ window: NSWindow) {
        let removed = entries.removeValue(forKey: ObjectIdentifier(window))?.1
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
