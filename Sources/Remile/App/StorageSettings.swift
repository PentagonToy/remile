import SwiftUI
import AppKit

struct StorageSettings: View {
    @AppStorage(StorageLocation.preference) private var storagePath = ""
    @AppStorage(StorageLocation.pendingPreference) private var pendingPath = ""
    @AppStorage(StoragePaths.referencePreference) private var referencePath = ""
    @AppStorage(StoragePaths.settingsPreference) private var settingsPath = ""
    @AppStorage(StoragePaths.readOnlyPreference) private var readOnlyPath = ""
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var message: String?; @Published var showsLocations = false }
    var body: some View {
        let root = StoragePaths.reference()
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/local.remile.app.plist")
        Form {
            Section("Storage") {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(RemileStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Storage folder").font(RemileType.callout.weight(.medium))
                        Text((StorageLocation.root().path as NSString).abbreviatingWithTildeInPath).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading).remileHelp(StorageLocation.root().path)
                    Menu("Change…") {
                        Button("Move storage…") { chooseStorage(existing: false) }
                        Button("Open storage…") { chooseStorage(existing: true) }
                    }.fixedSize()
                    reveal(StorageLocation.root(), directory: true)
                }
                Text("Reference and search data. Search indexes stay separate for each Mac.").font(RemileType.caption).foregroundStyle(.secondary)
                if !pendingPath.isEmpty {
                    HStack {
                        Text("Restart remile to apply the storage change.").font(RemileType.caption)
                        Spacer()
                        Button("Cancel change") { pendingPath = ""; state.message = nil }
                    }
                }
                if !referencePath.isEmpty {
                    Toggle("Read only", isOn: Binding(get: { StoragePaths.isReadOnly(root) }, set: { value in
                        readOnlyPath = value ? root.standardizedFileURL.path : ""
                        NotificationCenter.default.post(name: StoragePaths.changed, object: nil)
                    })).remileHelp("Enable editing on one Mac at a time after folder sync finishes")
                }
            }
            Section("Settings") {
                HStack {
                    Text("Preferences")
                    Spacer()
                    Text("~/Library/Preferences").font(RemileType.caption).foregroundStyle(.secondary)
                    reveal(preferences)
                }
            }
            Section("Presets") { SettingsTransferView(compact: true) }
            Section {
                DisclosureGroup("Locations", isExpanded: $state.showsLocations) {
                    VStack(alignment: .leading, spacing: 10) {
                        location("Reference", url: root, directory: true)
                        location("Search index", url: StorageLocation.search())
                        location("Preferences", url: preferences)
                        if !settingsPath.isEmpty { location("Settings export", url: URL(fileURLWithPath: settingsPath)) }
                    }.padding(.top, 10).padding(.leading, 18)
                }
            }
            if let message = state.message {
                Section {
                    Text(message).font(RemileType.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).font(RemileType.control).toggleStyle(.switch)
    }
    private func reveal(_ url: URL, directory: Bool = false) -> some View {
        Button {
            if directory { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) }
            else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } label: { Image(systemName: "arrow.up.forward.square") }
            .accessibilityLabel("Show in Finder").remileHelp("Show in Finder")
    }
    private func location(_ title: String, url: URL, directory: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title).font(RemileType.caption.weight(.medium)); Spacer(); reveal(url, directory: directory) }
            Text((url.path as NSString).abbreviatingWithTildeInPath).font(RemileType.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).remileHelp(url.path)
        }.padding(.vertical, 4)
    }
    private func chooseStorage(existing: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = existing ? "Open" : "Choose"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            let destination = existing ? selected : selected.appendingPathComponent("remile-storage", isDirectory: true)
            try StoragePaths.scheduleStorage(destination)
            pendingPath = destination.path
            state.message = nil
        } catch { state.message = error.localizedDescription }
    }
}
