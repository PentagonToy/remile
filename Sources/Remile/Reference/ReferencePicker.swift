import SwiftUI

/// Read the catalogue only while requested. No polling or duplicate attachment loading.
struct ReferencePicker: View {
    let format: ReferenceCitation.Format
    var insert: ((ReferenceRecord, String) throws -> Void)? = nil
    var bibliographies: [String] = []
    var context = "shared"
    var changed: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject {
        @Published var evidence: ReferenceRecord?
        @Published var matches: [ReferenceRecord] = []
        var entries: [ReferenceCitationIndex.Entry] = []
        @Published var libraries: [ReferenceLibrary] = []
        @Published var selected = Set<UUID>()
        @Published var query = ""
        @Published var message: String?
        @Published var loading = true
        @Published var bibliography = ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Reference").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            if state.loading { ProgressView() }
            else if state.libraries.isEmpty { Text("Add a library in Reference to begin.").foregroundStyle(.secondary) }
            else {
                HStack {
                    Text("Use for citations").font(RemileType.callout)
                    Menu {
                        ForEach(state.libraries) { library in
                            Toggle(library.name, isOn: Binding(get: { state.selected.contains(library.id) }, set: { use in
                                if use { state.selected.insert(library.id) } else { state.selected.remove(library.id) }
                            }))
                        }
                    } label: { Label(selectionTitle, systemImage: "books.vertical") }
                    .remileHelp("Choose one or more libraries for this document's citation suggestions.")
                    Spacer()
                }
                if insert != nil, format == .latex, bibliographies.count > 1 {
                    Picker("Bibliography", selection: $state.bibliography) {
                        Text("Choose a .bib file").tag("")
                        ForEach(bibliographies, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Find a reference", text: $state.query).textFieldStyle(.roundedBorder)
                List(state.matches) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.displayTitle).font(.headline)
                        Text([record.displayContributors, record.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(record.citationKey).font(.caption.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("View source") { state.evidence = record }
                            Button("Copy citation") { perform { let text = try ReferenceCitation.text(record, format: format); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); state.message = "Citation copied." } }
                            if let insert { Button("Insert citation") { perform { try insert(record, state.bibliography); dismiss() } }.disabled(format == .latex && state.bibliography.isEmpty) }
                        }
                    }.padding(.vertical, 6)
                }.listStyle(.plain)
            }
            if let message = state.message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text(format == .latex ? "Adds to the selected bibliography. Existing entries stay unchanged." : "Copies Markdown citation syntax. Bibliography rendering depends on your export tool.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 620, height: 520).background(RemileStyle.background).tint(RemileStyle.accent)
            .sheet(item: $state.evidence) { ReferenceEvidenceView(record: $0, format: format) }
            .task {
                let remembered = ReferenceCitationPreferences.read(context)
                state.selected = remembered.libraries != nil || remembered.library != nil ? remembered.selectedLibraries : [ReferenceLibrary.primaryID]
                state.bibliography = ReferenceCitationPreferences.destination(bibliographies, preferred: remembered.bibliography) ?? ""
                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        let snapshot = try ReferenceRepository().snapshot()
                        let hidden = Set(snapshot.libraries.filter { $0.trashed != nil }.map(\.id))
                        let libraries = snapshot.libraries.filter { !hidden.contains($0.id) && $0.parentID.map(hidden.contains) != true }
                        let records = snapshot.records.filter { $0.trashed == nil && !hidden.contains($0.library) && $0.collectionID.map(hidden.contains) != true }
                        try Task.checkCancellation()
                        return (libraries, ReferenceCitationIndex(records, byTitle: true))
                    }
                    let (libraries, index) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    state.libraries = libraries; state.entries = index.entries
                    state.selected.formIntersection(Set(libraries.map(\.id)))
                    if state.selected.isEmpty, remembered.libraries == nil, let first = libraries.first { state.selected = [first.id] }
                } catch { if !Task.isCancelled { state.message = error.localizedDescription } }
                guard !Task.isCancelled else { return }
                filter()
                state.loading = false
                if state.message == nil { remember() }
            }
            .onChange(of: state.selected) { if !state.loading { filter(); remember() } }
            .onChange(of: state.query) { filter() }
            .onChange(of: state.bibliography) { if !state.loading { remember() } }
    }
    private func filter() {
        let words = ReferenceCitationIndex.fold(state.query).split(whereSeparator: \.isWhitespace).map(String.init)
        state.matches = state.entries.filter { entry in
            ReferenceCitationPreferences.includes(entry.record, libraries: state.selected) && words.allSatisfy { entry.search.contains($0) }
        }.map(\.record)
    }
    private func remember() {
        let ids = state.selected.sorted { $0.uuidString < $1.uuidString }
        ReferenceCitationPreferences.write(.init(library: ids.first, bibliography: state.bibliography.isEmpty ? nil : state.bibliography, libraries: ids), context: context)
        changed()
    }
    private var selectionTitle: String {
        let names = state.libraries.filter { state.selected.contains($0.id) }.map(\.name)
        return names.isEmpty ? "Choose libraries…" : names.count == 1 ? names[0] : "\(names.count) libraries"
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { state.message = error.localizedDescription } }
}
