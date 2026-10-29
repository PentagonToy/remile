import SwiftUI

struct LibraryManager: View {
    @ObservedObject var model: HomeModel
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var documents: [LibraryIndexedDocument] = []; @Published var loadError: String?; @Published var coverageFolder: LibraryFolder? }
    private var coverageSummary: String {
        var parts: [String] = []
        if model.summary.needsOCR > 0 { parts.append("\(model.summary.needsOCR.formatted()) pages without text") }
        if model.summary.failed > 0 { parts.append("\(model.summary.failed.formatted()) files not indexed") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SymbolLabel("Library", systemImage: "folder").font(RemileType.heading)
                Spacer()
                Button("Close") { model.libraryPresented = false }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button(action: model.addFolder) { SymbolLabel("Add to Library…", systemImage: "folder.badge.plus") }.disabled(model.indexing)
                if model.indexing { Button("Stop", action: model.cancelIndexing) }
                else { Button("Update Index") { model.refresh() }.disabled(model.summary.folders.isEmpty) }
                if !model.indexing, let message = model.message {
                    SymbolLabel(message, systemImage: "checkmark.circle")
                        .font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1).remileHelp(message)
                }
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
                        SymbolIcon(systemName: "folder").foregroundStyle(RemileStyle.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name).font(RemileType.section)
                            Text(folder.path).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { state.coverageFolder = folder } label: {
                            SymbolIcon(systemName: state.loadError != nil || state.documents.contains(where: { $0.path.hasPrefix(folder.path.hasSuffix("/") ? folder.path : folder.path + "/") }) ? "exclamationmark.circle" : "checkmark.circle")
                        }
                            .buttonStyle(.plain).remileHelp("Search coverage for this folder").accessibilityLabel("Search coverage for " + folder.name)
                        Button { model.reindex(folder) } label: { SymbolIcon(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).remileHelp("Reindex this folder, including unchanged files").accessibilityLabel("Reindex " + folder.name).disabled(model.indexing)
                        Button { model.removeFolder(folder) } label: { SymbolIcon(systemName: "minus.circle") }.buttonStyle(.plain).remileHelp("Remove from Library · keep original files").disabled(model.indexing)
                    }.padding(.vertical, 8)
                }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            if model.indexing {
                if let progress = model.progress, !progress.preparingSearch {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    Text("\(progress.completed) of \(progress.total) · \(progress.name)").font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    HStack(spacing: RemileControl.spacing) {
                        ProgressView().controlSize(.small)
                        Text(model.progress?.preparingSearch == true ? "Preparing search…" : "Preparing index…")
                            .font(RemileType.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if model.summary.needsOCR > 0 || model.summary.failed > 0 {
                Text(coverageSummary).font(RemileType.caption).foregroundStyle(.secondary)
            }
        }.alert("Unable to update Library", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(item: $state.coverageFolder) { folder in
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Search coverage").font(RemileType.heading)
                    Spacer()
                    Button("Close") { state.coverageFolder = nil }.keyboardShortcut(.cancelAction)
                }
                Text(folder.name).font(RemileType.section)
                Text("Pages without text need Scan & OCR before they can be searched.").font(RemileType.small).foregroundStyle(.secondary)
                let documents = state.documents.filter { $0.path.hasPrefix(folder.path.hasSuffix("/") ? folder.path : folder.path + "/") }
                if documents.isEmpty && state.loadError == nil {
                    ContentUnavailableView("No coverage issues", systemImage: "checkmark.circle")
                } else {
                    List(documents) { document in
                        HStack {
                            Text(URL(fileURLWithPath: document.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(document.status).foregroundStyle(RemileStyle.warning)
                        }.font(RemileType.caption).remileHelp(document.path)
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                    if let error = state.loadError { Text(error).foregroundStyle(RemileStyle.warning) }
                }
            }.padding(24).frame(width: 580, height: 380).background(RemileStyle.background)
                .foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent).buttonStyle(RemileActionStyle())
        }
        .font(RemileType.control).buttonStyle(RemileActionStyle()).padding(24).frame(width: 620, height: 420).background(RemileStyle.background).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent)
            .task(id: model.libraryRevision) {
                do { state.documents = try await model.index.indexedDocuments(issuesOnly: true); state.loadError = nil }
                catch { state.loadError = "Could not read document status. Update the index and try again." }
            }
    }
}
