import SwiftUI
import AppKit

final class DeerstalkerDelegate: NSObject, NSApplicationDelegate {
    var reader: ReadingSession?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { reader?.confirmLeaving() == false ? .terminateCancel : .terminateNow }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}

@main
struct DeerstalkerApp: App {
    @NSApplicationDelegateAdaptor(DeerstalkerDelegate.self) private var delegate
    @StateObject private var home = HomeModel()

    var body: some Scene {
        Window("Deerstalker", id: "home") {
            ReadingShell(home: home, reader: home.reader).modifier(ReaderAppearanceModifier())
                .onAppear { delegate.reader = home.reader }
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
            Button("Open…") { if let url = model.chooseDocument() { model.open(url) }; openWindow(id: "home") }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.reader.save() }.keyboardShortcut("s")
            Button("Save a Copy…") { model.reader.saveCopy() }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Button("Close Document") {
                if model.reader.url != nil { model.reader.close() }
                else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w")
        }
        CommandGroup(after: .newItem) {
            Button("Home") { guard model.reader.close() else { return }; model.page = .home; openWindow(id: "home") }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Search Library") { guard model.reader.close() else { return }; model.page = .search; openWindow(id: "home") }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}
