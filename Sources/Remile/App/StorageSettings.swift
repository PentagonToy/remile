import SwiftUI
import AppKit

struct StorageSettings: View {
    @AppStorage(StoragePaths.referencePreference) private var referencePath = ""
    @AppStorage(StoragePaths.settingsPreference) private var settingsPath = ""
    @AppStorage(StoragePaths.readOnlyPreference) private var readOnlyPath = ""
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var busy = false; @Published var message: String?; @Published var previous: URL?; @Published var showsLocations = false }
    var body: some View {
        let root = StoragePaths.reference()
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/local.remile.app.plist")
        Form {
            Section("Reference") {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(RemileStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Library folder").font(RemileType.callout.weight(.medium))
                        Text((root.path as NSString).abbreviatingWithTildeInPath).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading).remileHelp(root.path)
                    if state.busy { ProgressView().controlSize(.small) }
                    Menu("Change…") {
                        Button("Move library…", action: relocate)
                        Button("Open library…", action: openLibrary)
                    }.fixedSize().disabled(state.busy)
                    reveal(root, directory: true)
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
                        location("Preferences", url: preferences)
                        if !settingsPath.isEmpty { location("Settings export", url: URL(fileURLWithPath: settingsPath)) }
                    }.padding(.top, 10).padding(.leading, 18)
                }
            }
            if let message = state.message {
                Section {
                    Text(message).font(RemileType.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let previous = state.previous { Button("Show previous copy") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: previous.path) } }
                }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
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
    private func relocate() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        state.busy = true; state.message = nil; state.previous = nil
        Task { @MainActor in
            defer { state.busy = false }
            do {
                let old = StoragePaths.reference()
                let destination = try await Task.detached(priority: .userInitiated) {
                    let repository = ReferenceRepository()
                    return try repository.withLibraryLock {
                        guard repository.root.standardizedFileURL == old.standardizedFileURL else { throw StoragePaths.Failure("The storage location changed. Open Storage again.") }
                        _ = try repository.snapshot()
                        return try StoragePaths.relocate(from: old, into: parent, commit: { publish in
                            try DispatchQueue.main.sync {
                                try MainActor.assumeIsolated {
                                    let opened = RemileWindows.shared.models.contains { model in
                                        model.reader.url.map { $0.standardizedFileURL.path.hasPrefix(old.standardizedFileURL.path + "/") } == true
                                    }
                                    guard !opened else { throw StoragePaths.Failure("Close PDFs opened from Reference before moving the library.") }
                                    try publish()
                                }
                            }
                        })
                    }
                }.value
                referencePath = destination.path
                NotificationCenter.default.post(name: StoragePaths.changed, object: nil)
                state.previous = old; state.message = "Library moved. Previous copy kept."
            } catch { state.message = error.localizedDescription }
        }
    }
    private func openLibrary() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.prompt = "Open"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        state.busy = true; state.message = nil; state.previous = nil
        Task { @MainActor in
            defer { state.busy = false }
            do {
                let current = StoragePaths.reference()
                guard !RemileWindows.shared.models.contains(where: { $0.reader.url?.standardizedFileURL.path.hasPrefix(current.standardizedFileURL.path + "/") == true }) else {
                    throw StoragePaths.Failure("Close PDFs opened from Reference before switching libraries.")
                }
                try await Task.detached(priority: .userInitiated) {
                    try StoragePaths.connect(to: folder, commit: { publish in
                        try DispatchQueue.main.sync {
                            try MainActor.assumeIsolated {
                                guard StoragePaths.reference() == current,
                                      !RemileWindows.shared.models.contains(where: { $0.reader.url?.standardizedFileURL.path.hasPrefix(current.standardizedFileURL.path + "/") == true }) else {
                                    throw StoragePaths.Failure("Close Reference PDFs and try switching libraries again.")
                                }
                                try publish()
                            }
                        }
                    })
                }.value
                referencePath = StoragePaths.reference().path; readOnlyPath = referencePath
                NotificationCenter.default.post(name: StoragePaths.changed, object: nil)
                state.message = "Library opened read only."
            } catch { state.message = error.localizedDescription }
        }
    }
}
