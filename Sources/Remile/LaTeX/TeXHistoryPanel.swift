import SwiftUI

struct TeXHistoryPanel: View {
    @ObservedObject var project: TeXProject
    @StateObject private var state = HistoryState()
    private final class HistoryState: ObservableObject { @Published var selected: UUID? }
    private var revisions: [TeXHistory.Revision] { project.revisions.filter { $0.file == project.selected } }
    private var revision: TeXHistory.Revision? { revisions.first { $0.id == state.selected } ?? revisions.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("History").font(RemileType.heading)
            }.buttonStyle(RemileToolStyle()).padding(10)
            Divider()
            HSplitView {
                List(revisions, selection: $state.selected) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.date.formatted(date: .abbreviated, time: .standard)).font(RemileType.caption)
                        if let marker = item.marker { Label(marker, systemImage: "wand.and.stars").font(.caption).foregroundStyle(Color(nsColor: RemileStyle.navy)) }
                        Text(item.file).font(RemileType.small).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.vertical, 4).tag(item.id)
                }.frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                VStack(alignment: .leading, spacing: 0) {
                    if let revision {
                        HStack {
                            Text(revision.file).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Restore to editor") { project.restore(revision) }.disabled(project.buffers[revision.file] == nil)
                        }.font(RemileType.caption).padding(12)
                        Divider()
                        ScrollView { Text(String(revision.source.prefix(300000))).font(.system(size: 14, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                    } else { ContentUnavailableView("No history for this file", systemImage: "clock") }
                }.frame(minWidth: 240)
            }
        }.background(RemileStyle.sidebar)
    }
}
