import SwiftUI

struct LibraryManager: View {
    @ObservedObject var model: HomeModel
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var documents: [LibraryIndexedDocument] = []; @Published var loadError: String? }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Library", systemImage: "folder").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { model.libraryPresented = false }.keyboardShortcut(.defaultAction)
            }
            HStack {
                Button(action: model.addFolder) { Label("Add to Library…", systemImage: "folder.badge.plus") }.disabled(model.indexing)
                if model.indexing { Button("Stop", action: model.cancelIndexing) }
                else { Button("Update Index") { model.refresh() }.disabled(model.summary.folders.isEmpty) }
                Spacer()
                Text("\(model.summary.documents) documents").font(RemileType.caption).foregroundStyle(.secondary)
            }
            if model.summary.folders.isEmpty {
                ContentUnavailableView("Choose folders to index", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                ForEach(model.summary.folders) { folder in
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(RemileStyle.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name).font(RemileType.heading)
                            Text(folder.path).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { model.reindex(folder) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).remileHelp("Reindex this folder, including unchanged files").accessibilityLabel("Reindex " + folder.name).disabled(model.indexing)
                        Button { model.removeFolder(folder) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).remileHelp("Remove from Library · keep original files").disabled(model.indexing)
                    }.padding(.vertical, 8)
                }
                DisclosureGroup("Documents · \(model.summary.documents)") {
                    ForEach(state.documents) { document in
                        HStack {
                            Text(URL(fileURLWithPath: document.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(document.status).foregroundStyle(document.failed || document.emptyPages > 0 ? RemileStyle.warning : RemileStyle.success).fixedSize(horizontal: false, vertical: true)
                        }.font(RemileType.caption).padding(.vertical, 4).remileHelp(document.path)
                    }
                    if model.summary.documents > 2000 { Text("Showing the first 2,000 documents").font(RemileType.caption).foregroundStyle(.secondary) }
                    if let error = state.loadError { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
                }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            if model.indexing {
                if let progress = model.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    Text("\(progress.completed) of \(progress.total) · \(progress.name)").font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1)
                } else { ProgressView("Preparing index…").controlSize(.small) }
            } else if let message = model.message { Label(message, systemImage: "checkmark.circle").font(RemileType.caption).foregroundStyle(.secondary) }
            if model.summary.needsOCR > 0 || model.summary.failed > 0 {
                Text("\(model.summary.needsOCR) pages without text · \(model.summary.failed) documents not indexed").font(RemileType.caption).foregroundStyle(.secondary)
            }
        }.alert("Unable to update Library", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .padding(24).frame(width: 620, height: 420).background(RemileStyle.background).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent)
            .task(id: model.libraryRevision) {
                do { state.documents = try await model.index.indexedDocuments(); state.loadError = nil }
                catch { state.loadError = "Could not read document status. Update the index and try again." }
            }
    }
}
