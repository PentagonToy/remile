import SwiftUI
import AppKit

struct StorageSettings: View {
    @AppStorage(StorageLocation.pendingPreference) private var pendingPath = ""
    @AppStorage(StoragePaths.pendingReferencePreference) private var pendingReference = ""
    @AppStorage(StoragePaths.pendingReferenceOpen) private var pendingReferenceOpen = false
    @AppStorage(StoragePaths.readOnlyPreference) private var readOnlyPath = ""
    @State private var message: String?

    private enum Location {
        case storage, reference

        var title: String { self == .storage ? "Storage folder" : "Reference folder" }
        var hint: String {
            self == .storage ? "Search indexes and Overleaf edit marks." : "Reference records and PDFs."
        }
    }

    var body: some View {
        let reference = StoragePaths.reference()
        Form {
            Section("Locations") {
                location(.storage, url: StorageLocation.root())
                location(.reference, url: reference)
                if reference.standardizedFileURL != StoragePaths.defaultReference.standardizedFileURL || readOnlyPath == reference.standardizedFileURL.path {
                    Toggle("Reference read only", isOn: Binding(get: { readOnlyPath == reference.standardizedFileURL.path }, set: { value in
                        readOnlyPath = value ? reference.standardizedFileURL.path : ""
                        NotificationCenter.default.post(name: StoragePaths.changed, object: nil)
                    })).remileHelp("Enable editing on one Mac at a time after folder sync finishes")
                }
                if !pendingPath.isEmpty || !pendingReference.isEmpty {
                    HStack {
                        Text("Restart remile to apply folder changes.").font(RemileType.caption)
                        Spacer()
                        Button("Cancel changes") { pendingPath = ""; pendingReference = ""; pendingReferenceOpen = false; message = nil }
                    }
                }
                if let message {
                    Text(message).font(RemileType.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Presets") { SettingsTransferView() }
        }.formStyle(.grouped).scrollContentBackground(.hidden).font(RemileType.control).toggleStyle(.switch)
    }

    private func location(_ location: Location, url: URL) -> some View {
        HStack(spacing: 10) {
            SymbolIcon(systemName: "folder").foregroundStyle(RemileStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(location.title).font(RemileType.callout.weight(.medium)).foregroundStyle(.primary)
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).remileHelp(url.path)
                Text(location.hint).fixedSize(horizontal: false, vertical: true)
            }.font(RemileType.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu("Change…") {
                Button(location == .storage ? "Move storage…" : "Move library…") { choose(location, opening: false) }
                Button(location == .storage ? "Open storage…" : "Open library…") { choose(location, opening: true) }
            }.fixedSize().accessibilityLabel("Change " + location.title.lowercased())
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) } label: {
                SymbolIcon(systemName: "arrow.up.forward.square")
            }.accessibilityLabel("Show " + location.title.lowercased() + " in Finder").remileHelp("Show in Finder")
        }
    }

    private func choose(_ location: Location, opening: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = opening ? "Open" : "Choose"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            if location == .storage {
                let destination = opening ? selected : selected.appendingPathComponent("remile-storage", isDirectory: true)
                if !opening, FileManager.default.fileExists(atPath: destination.path) {
                    throw StoragePaths.Failure("Choose a parent folder without a remile-storage folder.")
                }
                try StoragePaths.scheduleStorage(destination)
            } else {
                try StoragePaths.scheduleReference(selected, opening: opening)
            }
            message = nil
        } catch { message = error.localizedDescription }
    }
}
