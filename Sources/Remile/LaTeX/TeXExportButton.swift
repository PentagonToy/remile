import SwiftUI

/// Use the same native symbol and control size as adjacent workspace tools.
struct TeXExportButton: View {
    @ObservedObject var project: TeXProject
    var body: some View {
        Menu {
            Button("PDF…") { project.export() }.disabled(project.pdf == nil)
            Button("Source (.zip)…") { project.exportSource() }
        } label: {
            DocumentActionIcon(action: .export).frame(width: 32, height: 32)
        }.menuStyle(.borderlessButton).tint(RemileStyle.ink).menuIndicator(.hidden).fixedSize()
            .tint(RemileStyle.ink).foregroundStyle(RemileStyle.ink)
            .accessibilityLabel("Export").remileHelp("Export PDF or source")
    }
}
