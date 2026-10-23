import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsTransferView: View {
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var pending: PortableSettings.Snapshot?; @Published var message: String? }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Button("Export settings…", action: export); Button("Import settings…", action: choose) }
            SettingsHint("Move preferences between Macs using a settings file in iCloud Drive or Dropbox. Libraries, documents and accounts are separate.")
            if let message = state.message { Text(message).font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.alert("Import settings?", isPresented: Binding(get: { state.pending != nil }, set: { if !$0 { state.pending = nil } })) {
            Button("Cancel", role: .cancel) { state.pending = nil }
            Button("Import") { do { if let snapshot = state.pending { try PortableSettings.apply(snapshot); state.message = "Settings imported. Reopen a workspace to apply its panel widths." } } catch { state.message = error.localizedDescription }; state.pending = nil }
        } message: { Text("Replace the preferences included in this file? Documents, libraries, accounts and credentials stay on this Mac.") }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "remile-settings.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let snapshot = PortableSettings.snapshot(); try PortableSettings.validate(snapshot); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(snapshot).write(to: url, options: .atomic); state.message = "Settings exported." } catch { state.message = error.localizedDescription }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000 else { throw PortableSettings.Failure("Choose a settings file smaller than 64 KB.") }
            let snapshot = try JSONDecoder().decode(PortableSettings.Snapshot.self, from: Data(contentsOf: url)); try PortableSettings.validate(snapshot); state.pending = snapshot
        } catch { state.message = error.localizedDescription }
    }
}
