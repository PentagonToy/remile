import SwiftUI

struct TeXHistoryPanel: View {
    @ObservedObject var project: TeXProject
    @StateObject private var state = HistoryState()
    private final class HistoryState: ObservableObject { @Published var selected: UUID? }
    private var revisions: [TeXHistory.Revision] { project.revisions.filter { $0.file == project.selected } }
    private var revision: TeXHistory.Revision? { revisions.first { $0.id == state.selected } ?? revisions.first }
    private let headerHeight: CGFloat = 52
    var body: some View {
        ZStack(alignment: .top) {
            if revisions.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 34, weight: .light)).foregroundStyle(RemileStyle.accent)
                    Text("No history for this file").font(RemileType.heading)
                    Text(project.connected ? "Local snapshots are not saved for connected projects." : "Earlier edits will appear here.")
                        .font(RemileType.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, headerHeight + 1)
            } else {
                ReaderSplit(initial: 180, minimum: 140, maximum: 240, minimumContent: 220, label: "history versions", pane: {
                    List(revisions, selection: $state.selected) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(RemileType.caption)
                            if let marker = item.marker { Label(marker, systemImage: "wand.and.stars").font(RemileType.small).foregroundStyle(RemileStyle.accent) }
                            Text(item.file).font(RemileType.small).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }.padding(.vertical, 6).tag(item.id)
                    }.scrollContentBackground(.hidden).padding(.top, headerHeight + 1)
                }, content: {
                    VStack(alignment: .leading, spacing: 0) {
                        if let revision {
                            HStack {
                                Text(revision.file).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Restore to editor") { project.restore(revision) }.disabled(project.buffers[revision.file] == nil)
                            }.font(RemileType.caption).padding(12)
                            Divider()
                            ScrollView { Text(String(revision.source.prefix(300000))).font(.system(size: 14, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, headerHeight + 1)
                })
            }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(RemileStyle.accent)
                    Text("History").font(RemileType.heading)
                    Spacer(minLength: 8)
                    Button { project.showsHistory = false; project.showsLog = false } label: { Image(systemName: "doc.richtext") }.remileHelp("Show PDF").accessibilityLabel("Show PDF")
                }.buttonStyle(RemileToolStyle()).padding(.horizontal, 12).frame(height: headerHeight)
                Divider()
            }.background(RemileStyle.sidebar)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(RemileStyle.sidebar)
            .onChange(of: project.selected) { state.selected = nil }
    }
}
