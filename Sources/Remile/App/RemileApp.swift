import SwiftUI
import AppKit

@MainActor
final class RemileDelegate: NSObject, NSApplicationDelegate {
    private var automationTask: Task<Void, Never>?
    func bind() {
        guard automationTask == nil else { return }
        Task.detached(priority: .utility) { RetiredPublisherSession.clear(); TeXCache.prune() }
        automationTask = Task { @MainActor in await EditorBridge.serve { RemileWindows.shared.requestHome() } }
    }
    func applicationWillTerminate(_ notification: Notification) { automationTask?.cancel() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for home in RemileWindows.shared.models {
            if home.writer?.confirmLeaving() == false || !home.pdfSearchEditing.confirmLeaving() || home.texProject?.confirmLeaving() == false || !home.reader.confirmLeaving() { return .terminateCancel }
        }
        return .terminateNow
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        return menu
    }
    @objc private func newWindow() { RemileWindows.shared.createWindow?(); NSApp.activate(ignoringOtherApps: true) }
}

@main
struct RemileEntry {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--cli" { exit(EditorCLI.run(Array(CommandLine.arguments.dropFirst(2)))) }
        do { try LegacyMigration.run() }
        catch { let alert = NSAlert(); alert.messageText = "Could not migrate your library"; alert.informativeText = error.localizedDescription + " Your previous data is unchanged."; alert.runModal(); return }
        do { try StoragePaths.applyPendingStorage() }
        catch {
            let alert = NSAlert(); alert.messageText = "Storage was not changed"
            alert.informativeText = error.localizedDescription + " Your current storage is unchanged."
            alert.addButton(withTitle: "Use current storage"); alert.addButton(withTitle: "Try next launch")
            if alert.runModal() == .alertFirstButtonReturn { UserDefaults.standard.removeObject(forKey: StorageLocation.pendingPreference) }
        }
        RemileApp.main()
    }
}

struct RemileApp: App {
    @NSApplicationDelegateAdaptor(RemileDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("remile.", id: "home") { RemileWindow(delegate: delegate) }
            .defaultSize(width: 1120, height: 800)
            .commands { RemileCommands(); WorkspaceCommands() }
        Settings { ReaderSettings().modifier(ReaderAppearanceModifier()).modifier(NetworkAccessScope()) }
    }
}

private struct RemileWindow: View {
    let delegate: RemileDelegate
    @StateObject private var home = HomeModel()
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ReadingShell(home: home, reader: home.reader).modifier(ReaderAppearanceModifier()).modifier(NetworkAccessScope())
            .onAppear { RemileWindows.shared.createWindow = { openWindow(id: "home") }; delegate.bind() }
    }
}

private struct RemileCommands: Commands {
    @ObservedObject private var windows = RemileWindows.shared
    var body: some Commands {
        if let model = windows.active { HomeCommands(model: model) }
        else {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { windows.createWindow?() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("New Markdown") { windows.perform { $0.newMarkdown() } }.keyboardShortcut("n")
                Button("Open…") { windows.perform { if let url = $0.chooseDocument() { $0.open(url) } } }.keyboardShortcut("o")
            }
        }
    }
}

private struct HomeCommands: Commands {
    @ObservedObject var model: HomeModel
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("remile. User Guide") { model.guidePresented = true }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { RemileWindows.shared.createWindow?() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Writer") { model.newWriter() }
            Button("New Markdown") { model.newMarkdown() }.keyboardShortcut("n")
            Button("Open LaTeX Project…") { model.chooseTeX() }
            Divider()
            Button("Open…") { if let url = model.chooseDocument() { model.open(url) } }.keyboardShortcut("o")
        }
        CommandGroup(after: .importExport) {
            Button("Convert to PDF…") { model.presentConversion() }
            Button("Compress PDF…") { model.presentCompression(!model.reader.dirty && model.reader.url?.pathExtension.lowercased() == "pdf" ? model.reader.url : nil) }
            Button("Combine PDFs…") { model.create(.combine, open: model.open) }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { if model.page == .writer { model.writer?.printDocument() } else { NotificationCenter.default.post(name: Notification.Name("remile.print"), object: model.reader) } }.keyboardShortcut("p")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { if model.page == .writer { model.writer?.save() } else if let project = model.texProject { project.save() } else { model.reader.save() } }.keyboardShortcut("s")
            Button(model.page == .writer ? "Save As…" : "Save a Copy…") { if model.page == .writer, let writer = model.writer { writer.saveAs() } else { model.reader.saveCopy() } }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.texProject != nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Close Document") {
                if model.page == .writer { if model.writer?.confirmLeaving() != false { model.writer = nil; model.page = .home } }
                else if model.texProject != nil { model.closeTeX() }
                else if model.reader.url != nil { model.reader.close() }
                else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w")
        }
        CommandGroup(after: .textEditing) {
            Button("Toggle Comment") { NotificationCenter.default.post(name: Notification.Name("remile.toggleComment"), object: model.texProject) }.keyboardShortcut("/").disabled(model.texProject == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Home") { guard model.closeTeX(), model.reader.close() else { return }; model.page = .home }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Search Library") { guard model.closeTeX(), model.reader.close() else { return }; model.page = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}
