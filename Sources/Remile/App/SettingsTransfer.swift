import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsTransferView: View {
    var compact = false
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var pending: PortableSettings.Snapshot?; @Published var message: String? }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Button("Save preset…", action: export).remileHelp("Save appearance and editing preferences without accounts or library paths"); Button("Load preset…", action: choose).remileHelp("Load preferences from a preset") }
            if !compact { SettingsHint("Save a preset to use your preferences on another Mac.") }
            if let message = state.message { Text(message).font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.alert("Load preset?", isPresented: Binding(get: { state.pending != nil }, set: { if !$0 { state.pending = nil } })) {
            Button("Cancel", role: .cancel) { state.pending = nil }
            Button("Load") { do { if let snapshot = state.pending { try PortableSettings.apply(snapshot); state.message = "Preset loaded. Reopen a workspace to apply panel widths." } } catch { state.message = error.localizedDescription }; state.pending = nil }
        } message: { Text("Replace these preferences? Documents, libraries and accounts stay unchanged.") }
    }
    private func export() {
        let panel = NSSavePanel()
        if let path = UserDefaults.standard.string(forKey: StoragePaths.settingsPreference) { let url = URL(fileURLWithPath: path); panel.directoryURL = url.deletingLastPathComponent(); panel.nameFieldStringValue = url.lastPathComponent }
        else { panel.nameFieldStringValue = "remile-preset.json" }
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let snapshot = PortableSettings.snapshot(); try PortableSettings.validate(snapshot); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(snapshot).write(to: url, options: .atomic); UserDefaults.standard.set(url.path, forKey: StoragePaths.settingsPreference); state.message = "Preset saved." } catch { state.message = error.localizedDescription }
    }
    private func choose() {
        let panel = NSOpenPanel()
        if let path = UserDefaults.standard.string(forKey: StoragePaths.settingsPreference) { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000 else { throw PortableSettings.Failure("Choose a preset smaller than 64 KB.") }
            let snapshot = try JSONDecoder().decode(PortableSettings.Snapshot.self, from: Data(contentsOf: url)); try PortableSettings.validate(snapshot); state.pending = snapshot
        } catch { state.message = error.localizedDescription }
    }
}
