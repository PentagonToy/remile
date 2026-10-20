import SwiftUI

struct LibraryManager: View {
    @ObservedObject var model: HomeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Library", systemImage: "books.vertical").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { model.libraryPresented = false }.keyboardShortcut(.defaultAction)
            }
            HStack {
                Button(action: model.addFolder) { Label("Add to Library…", systemImage: "folder.badge.plus") }.disabled(model.indexing)
                if model.indexing { Button("Stop", action: model.cancelIndexing) }
                else { Button("Update Index", action: model.refresh).disabled(model.summary.folders.isEmpty) }
                Spacer()
                Text("\(model.summary.documents) documents").font(RemileType.caption).foregroundStyle(.secondary)
            }
            if model.summary.folders.isEmpty {
                ContentUnavailableView("Choose folders to index", systemImage: "folder.badge.plus")
            } else {
                List(model.summary.folders) { folder in
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(RemileStyle.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name).font(RemileType.heading)
                            Text(folder.path).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { model.removeFolder(folder) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove from Library; keep original files").disabled(model.indexing)
                    }.padding(.vertical, 8)
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
    }
}
