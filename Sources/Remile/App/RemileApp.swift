import SwiftUI
import AppKit

final class RemileDelegate: NSObject, NSApplicationDelegate {
    var reader: ReadingSession?
    var home: HomeModel?
    private var automationTask: Task<Void, Never>?
    @MainActor func bind(_ model: HomeModel) {
        home = model; reader = model.reader
        if automationTask == nil { UserDefaults.standard.set(false, forKey: "editor.aiSuggestions"); automationTask = Task { @MainActor in await EditorBridge.serve(model) } }
    }
    func applicationWillTerminate(_ notification: Notification) { automationTask?.cancel() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { (home?.texProject?.confirmLeaving() == false || reader?.confirmLeaving() == false) ? .terminateCancel : .terminateNow }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}

@main
struct RemileEntry {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--cli" { exit(EditorCLI.run(Array(CommandLine.arguments.dropFirst(2)))) }
        do { try LegacyMigration.run() }
        catch { let alert = NSAlert(); alert.messageText = "Could not migrate your library"; alert.informativeText = error.localizedDescription + " Your previous data is unchanged."; alert.runModal(); return }
        RemileApp.main()
    }
}

struct RemileApp: App {
    @NSApplicationDelegateAdaptor(RemileDelegate.self) private var delegate
    @StateObject private var home = HomeModel()

    var body: some Scene {
        Window("remile.", id: "home") {
            ReadingShell(home: home, reader: home.reader).modifier(ReaderAppearanceModifier())
                .onAppear { delegate.bind(home) }
        }
        .defaultSize(width: 1120, height: 800)
        .commands { HomeCommands(model: home) }
        Settings { ReaderSettings().modifier(ReaderAppearanceModifier()) }
    }
}

private struct HomeCommands: Commands {
    @ObservedObject var model: HomeModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Markdown") { model.newMarkdown(); openWindow(id: "home") }.keyboardShortcut("n")
            Button("Open LaTeX Project…") { model.chooseTeX() }
            Divider()
            Button("Open…") { if let url = model.chooseDocument() { model.open(url) }; openWindow(id: "home") }.keyboardShortcut("o")
        }
        CommandGroup(after: .importExport) {
            Button("Convert to PDF…") { model.presentConversion() }
            Button("Compress PDF…") { model.presentCompression(!model.reader.dirty && model.reader.url?.pathExtension.lowercased() == "pdf" ? model.reader.url : nil) }
            Button("Combine PDFs…") { model.create(.combine, open: model.open) }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { NotificationCenter.default.post(name: Notification.Name("remile.print"), object: nil) }.keyboardShortcut("p")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { if let project = model.texProject { project.save() } else { model.reader.save() } }.keyboardShortcut("s")
            Button("Save a Copy…") { model.reader.saveCopy() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.texProject != nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Close Document") {
                if model.texProject != nil { model.closeTeX() }
                else if model.reader.url != nil { model.reader.close() }
                else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w")
        }
        CommandGroup(after: .textEditing) {
            Button("Toggle Comment") { NotificationCenter.default.post(name: Notification.Name("remile.toggleComment"), object: nil) }.keyboardShortcut("/").disabled(model.texProject == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Home") { guard model.closeTeX(), model.reader.close() else { return }; model.page = .home; openWindow(id: "home") }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Search Library") { guard model.closeTeX(), model.reader.close() else { return }; model.page = .search; openWindow(id: "home") }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}
