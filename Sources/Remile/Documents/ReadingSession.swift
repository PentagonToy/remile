import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A document lives inside the main window; navigation never discards unsaved work.
@MainActor
final class ReadingSession: ObservableObject {
    @Published var document = ReadingDocument() {
        didSet {
            if case .markdown(let before) = oldValue.content, case .markdown(let after) = document.content, before != after { externalEdits = EditorProvenance.rebase(externalEdits, before: before, after: after) }
        }
    }
    @Published private(set) var externalEdits: [NSRange] = []
    var editSource: ((String, String) async -> Bool)?
    func markExternalEdit(before: String, after: String) { let range = EditorProvenance.change(before: before, after: after).inserted; externalEdits = EditorProvenance.merged(externalEdits + (range.length > 0 ? [range] : [])) }
    @Published private(set) var url: URL?
    @Published private(set) var isUntitled = false
    private var original = Data()
    var bytes: Data {
        switch document.content {
        case .pdf(let data): return data
        case .markdown(let text): return Data(text.utf8)
        }
    }
    var dirty: Bool { url != nil && (isUntitled || bytes != original) }
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
        externalEdits = []; editSource = nil
        document.content = content; original = data; url = destination; isUntitled = false
        if recordRecent { NSDocumentController.shared.noteNewRecentDocumentURL(destination) }
    }
    @discardableResult func newMarkdown() -> Bool {
        guard confirmLeaving() else { return false }
        externalEdits = []; editSource = nil
        document.content = .markdown(""); original = Data(); isUntitled = true
        url = URL(fileURLWithPath: "/remile-untitled-" + UUID().uuidString + "/Untitled.md")
        return true
    }
    func saveCopy() {
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
        externalEdits = []; editSource = nil
        url = nil; original = Data(); document = ReadingDocument(); isUntitled = false; return true
    }
}

struct ReadingShell: View {
    @ObservedObject var home: HomeModel
    @ObservedObject var reader: ReadingSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let project = home.texProject {
                TeXWorkspace(project: project, close: { home.closeTeX() })
            } else if let url = reader.url {
                DocumentWorkspace(document: $reader.document, fileURL: url, session: reader)
                    .id(url).transition(.opacity.combined(with: .offset(x: 12)))
                    .navigationTitle(url.deletingPathExtension().lastPathComponent + (reader.dirty ? " •" : ""))
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button { reader.close() } label: { Label("Home", systemImage: "chevron.left") }.help("Return to Home")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            if case .markdown = reader.document.content {
                                Button { NotificationCenter.default.post(name: Notification.Name("remile.exportMarkdownPDF"), object: nil) } label: { Image(systemName: "square.and.arrow.up").frame(width: 30, height: 30) }.help("Export PDF…")
                            } else { Menu {
                                Button("Convert to PDF…") { home.presentConversion() }
                                Button("Compress PDF…") { home.presentCompression(!reader.dirty && url.pathExtension.lowercased() == "pdf" ? url : nil) }
                                Button("Combine PDFs…") { home.create(.combine, open: home.open) }
                            } label: { Image(systemName: "plus").frame(width: 30, height: 30) }.help("Document tools") }
                        }
                    }
            } else { HomeWorkspace(model: home).transition(.opacity) }
        }
        .animation(reduceMotion ? nil : RemileMotion.navigation, value: reader.url)
        .frame(minWidth: 1000, minHeight: 650)
        .overlay { if home.opening { ProgressView("Opening document…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .background(WindowCloseGuard(reader: reader, home: home))
        .onOpenURL { home.open($0) }
        .sheet(isPresented: $home.convertPresented) { ConvertWorkspace(model: home.conversion) }
        .sheet(isPresented: $home.compressPresented) { CompressWorkspace(model: home.compression) }
        .sheet(isPresented: $home.combinePresented) { CombineWorkspace(model: home.combination, open: home.open) }
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
            window.delegate = context.coordinator
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let reader: ReadingSession
        let home: HomeModel
        weak var previous: NSWindowDelegate?
        init(reader: ReadingSession, home: HomeModel) { self.reader = reader; self.home = home }
        func windowShouldClose(_ sender: NSWindow) -> Bool { (previous?.windowShouldClose?(sender) ?? true) && home.closeTeX() && reader.close() }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector) }
    }
}
