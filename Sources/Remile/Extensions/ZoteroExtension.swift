import SwiftUI

@MainActor final class ZoteroExtensionModel: ObservableObject {
    @Published var libraries: [ZoteroLibrary] = []
    @Published var collections: [String: [ZoteroCollection]] = [:] {
        didSet { rowsByLibrary = collections.mapValues(Self.collectionRows) }
    }
    private(set) var rowsByLibrary: [String: [CollectionRow]] = [:]
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var phase = ""
    @Published var connected = false
    private let client: ZoteroLocalClient
    init(client: ZoteroLocalClient = ZoteroLocalClient()) { self.client = client }
    private var task: Task<Void, Never>?
    func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        do { try ZoteroAccess.requireEnabled() } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil
        task = Task { @MainActor [weak self] in
            defer { self?.busy = false; self?.phase = ""; self?.task = nil }
            do { try await work() }
            catch is CancellationError { self?.error = "Cancelled." }
            catch { self?.error = error.localizedDescription }
        }
    }
    func refresh() {
        run { [self] in
            phase = "Reading Zotero libraries…"
            let result = try await client.libraries()
            try Task.checkCancellation()
            libraries = result; collections = [:]
            phase = "Reading collections…"
            if let library = result.first {
                let items = try await client.collections(library)
                try Task.checkCancellation()
                collections[library.id] = items
            }
        }
    }
    func resumeConnection() {
        guard libraries.isEmpty, error != nil, !busy else { return }
        refresh()
    }
    func loadCollections(_ library: ZoteroLibrary) {
        guard collections[library.id] == nil else { return }
        run { [self] in
            phase = "Reading collections…"
            let result = try await client.collections(library)
            try Task.checkCancellation()
            guard collections.values.reduce(0, { $0 + $1.count }) + result.count <= 10000 else { throw ReferenceFailure("Open fewer Zotero libraries at once.") }
            collections[library.id] = result
        }
    }
    var scopes: [ZoteroScope] {
        libraries.flatMap { library in
            [ZoteroScope(library: library)] + (collections[library.id] ?? []).map { ZoteroScope(library: library, collection: $0) }
        }
    }
    func connect(_ selected: Set<String>, completion: @escaping () -> Void) {
        let available = Dictionary((scopes + ZoteroCitationSources.scopes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chosen = ZoteroFolderSelection.canonical(selected, scopes: Array(available.values)).sorted().compactMap { available[$0] }
        guard !chosen.isEmpty else { return }
        run { [self] in
            phase = "Connecting citation sources…"
            try await ZoteroCitationSources.shared.connect(chosen)
            connected = true
            completion()
        }
    }
    func importSelection(_ selected: Set<String>, to references: ReferenceModel, completion: @escaping () -> Void) {
        let available = Dictionary((scopes + ZoteroCitationSources.scopes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chosen = ZoteroFolderSelection.canonical(selected, scopes: Array(available.values)).sorted().compactMap { available[$0] }
        guard !chosen.isEmpty else { return }
        run { [self] in
            try await readSources(chosen, to: references)
            completion()
        }
    }
    func updateLibrary(_ library: ReferenceLibrary, to references: ReferenceModel) {
        guard let scope = library.importedZoteroScope else { return }
        run { [self] in try await readSources([scope], to: references, updating: library) }
    }
    private func readSources(_ chosen: [ZoteroScope], to references: ReferenceModel, updating: ReferenceLibrary? = nil) async throws {
        var total = 0, missing = 0
        for scope in chosen {
            var entries: [ZoteroImportEntry] = []
            var version: String?
            var finished = false
            let children: [ZoteroScope]
            if scope.collection != nil {
                let current = try await client.collections(scope.library)
                collections[scope.library.id] = current
                children = try ZoteroFolderSelection.descendants(scope, collections: current)
            } else { children = [scope] }
            var seen = Set<String>()
            for childScope in children {
                finished = false
                for start in stride(from: 0, to: 10000, by: 100) {
                    try Task.checkCancellation(); try ZoteroAccess.requireEnabled()
                    phase = "Reading " + (scope.collection?.name ?? scope.library.name) + "…"
                    let (items, nextVersion) = try await client.items(childScope, start: start)
                    if let version, let nextVersion, version != nextVersion { throw ReferenceFailure("Zotero changed. Refresh and try again.") }
                    version = nextVersion
                    for item in items where item.isReference && seen.insert(item.key).inserted {
                        total += 1
                        guard total <= 10000 else { throw ReferenceFailure("Import up to 10,000 references at once.") }
                        var files: [URL] = []
                        var fileKeys: [String] = []
                        var fileVersions: [Int] = []
                        phase = "Preparing reference " + String(total) + "…"
                        for child in try await client.children(item, in: scope.library) {
                            if let file = try await client.localPDF(child, in: scope.library) { files.append(file); fileKeys.append(child.key); fileVersions.append(child.version) }
                            else { missing += 1 }
                        }
                        var record = try item.reference(in: scope.library)
                        record.fields["zoterolibrary"] = scope.library.name
                        if let collection = childScope.collection { record.fields["zoterocollection"] = collection.name }
                        entries.append(ZoteroImportEntry(record: record, files: files, fileKeys: fileKeys, fileVersions: fileVersions))
                    }
                    if items.count < 100 { finished = true; break }
                }
                guard finished else { throw ReferenceFailure("Choose a smaller Zotero source.") }
            }
            if entries.isEmpty && updating == nil { continue }
            try Task.checkCancellation(); try ZoteroAccess.requireEnabled()
            phase = updating == nil ? "Adding to Reference…" : "Updating library…"
            let success: Bool = await withCheckedContinuation { continuation in
                references.importZotero(scope, entries: entries, updating: updating?.id) { continuation.resume(returning: $0) }
            }
            guard success else { throw ReferenceFailure(references.error ?? "Could not import this Zotero source.") }
            try Task.checkCancellation()
        }
        guard total > 0 || updating != nil else { throw ReferenceFailure("No references found in the selected sources.") }
        let result = updating == nil ? "Zotero references added." : "Zotero library updated."
        references.notice = missing == 0 ? result : result + " \(missing) PDFs were unavailable in Zotero."
    }
    func cancel() { task?.cancel(); if busy { phase = "Stopping…" } }
    func leave() { cancel() }
    struct CollectionRow: Identifiable {
        let collection: ZoteroCollection
        let path: [String]
        var id: String { collection.id }
    }
    static func collectionRows(_ items: [ZoteroCollection]) -> [CollectionRow] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.map { CollectionRow(collection: $0, path: collectionPath($0, byID: byID)) }.sorted {
            $0.path.joined(separator: " / ").localizedStandardCompare($1.path.joined(separator: " / ")) == .orderedAscending
        }
    }
    static func collectionPath(_ collection: ZoteroCollection, in items: [ZoteroCollection]) -> [String] {
        collectionPath(collection, byID: Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }
    private static func collectionPath(_ collection: ZoteroCollection, byID: [String: ZoteroCollection]) -> [String] {
        var parts = [collection.name], seen: Set<String> = [collection.id], parent = collection.parent
        while let key = parent, seen.insert(key).inserted, let item = byID[key] {
            parts.insert(item.name, at: 0); parent = item.parent
        }
        return parts
    }

}

struct ZoteroExtensionCard: View {
    @ObservedObject var references: ReferenceModel
    let showReference: () -> Void
    @AppStorage(ZoteroAccess.enabledKey) private var enabled = false
    @StateObject private var model = ZoteroExtensionModel()
    @State private var showConnection = false
    @State private var confirming = false
    @State private var pending = false
    var body: some View {
        HStack(spacing: RemileControl.spacing) {
            Button { showConnection = true } label: {
                VStack(alignment: .leading, spacing: RemileControl.spacing) {
                    HStack(spacing: RemileControl.spacing) {
                        Text("Z").font(RemileType.heading).frame(width: RemileControl.iconSlot, height: RemileControl.iconSlot).accessibilityHidden(true)
                        Text("Zotero").font(RemileType.heading)
                    }
                }.frame(maxWidth: .infinity, minHeight: RemileControl.toolHit, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!enabled).remileHelp("Choose Zotero libraries")
            Toggle("Zotero", isOn: Binding(get: { enabled }, set: { pending = $0; confirming = true }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Enable Zotero")
        }.padding(RemileControl.rowSpacing * 2).frame(maxWidth: .infinity, alignment: .leading)
            .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.card))
            .alert(pending ? "Enable Zotero?" : "Turn off Zotero?", isPresented: $confirming) {
                Button(pending ? "Enable" : "Turn off") { enabled = pending; if !enabled { model.leave(); Task { await ZoteroCitationSources.shared.clear() } } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(pending ? "Use this experimental integration at your own risk. Zotero originals stay unchanged." : "Zotero citation sources will be unavailable. Existing project bibliographies will remain.")
            }.sheet(isPresented: $showConnection) {
                ZoteroConnection(model: model, references: references, showReference: showReference)
            }
    }
}

struct ZoteroConnection: View {
    @ObservedObject var model: ZoteroExtensionModel
    @ObservedObject var references: ReferenceModel
    let showReference: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ZoteroAccess.enabledKey) private var enabled = false
    @State private var selected = Set<String>()
    @State private var expanded = Set<String>()
    @State private var query = ""
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: RemileControl.rowSpacing) {
            HStack {
                Text("Zotero").font(RemileType.heading)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy || references.busy)
            }
            if !model.libraries.isEmpty {
                Text("Keep Zotero running to use its libraries.").font(RemileType.caption).foregroundStyle(.secondary)
                TextField("Find a library or collection", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: RemileControl.spacing) {
                        ForEach(model.libraries) { library in libraryRow(library) }
                    }.frame(maxWidth: .infinity, alignment: .leading).scrollContentGutter()
                }.frame(height: 420)
            } else if !model.busy {
                VStack(alignment: .leading, spacing: RemileControl.spacing) {
                    Text("Connect to Zotero").font(RemileType.heading)
                    Text(model.error ?? "Open Zotero to see your libraries.")
                        .font(RemileType.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Zotero") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Zotero.app")) }
                }.padding(.vertical, RemileControl.rowSpacing)
            }
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.phase).font(RemileType.caption)
                    Spacer()
                    Button("Cancel") { model.cancel() }
                }.padding(.vertical, RemileControl.spacing)
            }
            if !model.libraries.isEmpty, let error = model.error {
                Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(model.libraries.isEmpty ? "Check again" : "Refresh") { expanded = []; model.refresh() }.disabled(model.busy)
                Text("\(selected.count) selected").font(RemileType.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("More") {
                    Button("Use as connected citation sources") { model.connect(selected) { dismiss() } }
                }.disabled(selected.isEmpty || model.busy || references.busy)
                Button("Add to Reference") {
                    model.importSelection(selected, to: references) { dismiss(); showReference() }
                }.disabled(selected.isEmpty || model.libraries.isEmpty || model.busy || references.busy)
            }
        }.padding(RemileControl.rowSpacing * 2).frame(width: 820)
            .background(RemileStyle.background).tint(RemileStyle.accent)
            .interactiveDismissDisabled(model.busy || references.busy)
            .task {
                selected = Set(ZoteroCitationSources.scopes.map(\.id))
                if let first = model.libraries.first { expanded.insert(first.id) }
                model.refresh()
            }
            .onChange(of: model.libraries) { _, libraries in
                if expanded.isEmpty, let first = libraries.first { expanded.insert(first.id) }
                selected = ZoteroFolderSelection.canonical(selected, scopes: model.scopes + ZoteroCitationSources.scopes)
            }
            .onChange(of: model.collections) { _, _ in
                selected = ZoteroFolderSelection.canonical(selected, scopes: model.scopes + ZoteroCitationSources.scopes)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.resumeConnection() }
            .onChange(of: enabled) { _, active in if !active { model.leave(); dismiss() } }
            .onDisappear { model.leave() }
    }
    private func selection(_ scope: ZoteroScope) -> Binding<Bool> {
        Binding(get: { selected.contains(scope.id) }, set: {
            if $0 { selected.insert(scope.id) } else { selected.remove(scope.id) }
            selected = ZoteroFolderSelection.canonical(selected, scopes: model.scopes + ZoteroCitationSources.scopes)
        })
    }
    private func libraryRow(_ library: ZoteroLibrary) -> some View {
        let rows = model.rowsByLibrary[library.id] ?? []
        let term = searchTerm
        let matches = term.isEmpty || library.name.localizedCaseInsensitiveContains(term)
        let byID = Dictionary(rows.map { ($0.id, $0.collection) }, uniquingKeysWith: { first, _ in first })
        let parents = Set(rows.compactMap { $0.collection.parent })
        let root = ZoteroScope(library: library)
        let states = collectionStates(rows, library: library)
        let rootState: NSControl.StateValue = selected.contains(root.id) ? .on : (selected.contains(where: { $0.hasPrefix(root.id) }) ? .mixed : .off)
        return LazyVStack(alignment: .leading, spacing: RemileControl.spacing) {
            if matches || rows.contains(where: { $0.path.joined(separator: " / ").localizedCaseInsensitiveContains(term) }) {
                scopeRow(root, title: library.name, depth: 0, hasChildren: !rows.isEmpty || model.collections[library.id] == nil, state: rootState)
                if expanded.contains(library.id) || !term.isEmpty {
                    ForEach(rows.filter { rowVisible($0, library: library, byID: byID, searching: !term.isEmpty) && (matches || $0.path.joined(separator: " / ").localizedCaseInsensitiveContains(term)) }) { row in
                        scopeRow(ZoteroScope(library: library, collection: row.collection), title: row.collection.name,
                            depth: min(row.path.count, 8), hasChildren: parents.contains(row.id), state: states[row.id] ?? .off)
                    }
                }
            }
        }
    }
    private func rowVisible(_ row: ZoteroExtensionModel.CollectionRow, library: ZoteroLibrary, byID: [String: ZoteroCollection], searching: Bool) -> Bool {
        if searching { return true }
        var parent = row.collection.parent, seen = Set<String>()
        while let id = parent, seen.insert(id).inserted {
            guard expanded.contains(library.id + ":" + id) else { return false }
            parent = byID[id]?.parent
        }
        return true
    }
    private func collectionStates(_ rows: [ZoteroExtensionModel.CollectionRow], library: ZoteroLibrary) -> [String: NSControl.StateValue] {
        let rootSelected = selected.contains(ZoteroScope(library: library).id)
        let byID = Dictionary(rows.map { ($0.id, $0.collection) }, uniquingKeysWith: { first, _ in first })
        var states: [String: NSControl.StateValue] = [:]
        for row in rows {
            if rootSelected || selected.contains(library.id + ":" + row.id) || row.collection.parent.map({ states[$0] == .on }) == true { states[row.id] = .on }
        }
        for row in rows where selected.contains(library.id + ":" + row.id) {
            var parent = row.collection.parent, seen: Set<String> = [row.id]
            while let key = parent, seen.insert(key).inserted {
                if states[key] != .on { states[key] = .mixed }
                parent = byID[key]?.parent
            }
        }
        return states
    }
    private func scopeRow(_ scope: ZoteroScope, title: String, depth: Int, hasChildren: Bool, state: NSControl.StateValue) -> some View {
        let expansion = scope.collection == nil ? scope.library.id : scope.id
        return HStack(spacing: RemileControl.spacing) {
            SourceFolderCheckbox(state: state, label: title, enabled: !model.busy && (state != .on || selected.contains(scope.id))) {
                selection(scope).wrappedValue = $0
            }.frame(width: RemileControl.height, height: RemileControl.height)
            Button {
                if !expanded.insert(expansion).inserted { expanded.remove(expansion) }
                if scope.collection == nil { model.loadCollections(scope.library) }
            } label: {
                SymbolIcon(systemName: expanded.contains(expansion) ? "chevron.down" : "chevron.right")
                    .opacity(hasChildren ? 1 : 0)
            }.buttonStyle(.plain).disabled(model.busy || !hasChildren).accessibilityLabel("Expand " + title)
            Button { selection(scope).wrappedValue = state != .on } label: {
                SymbolLabel(title, systemImage: scope.collection == nil ? "tray.full" : "folder")
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy || (state == .on && !selected.contains(scope.id)))
        }.padding(.vertical, RemileControl.spacing).padding(.horizontal, RemileControl.spacing)
            .padding(.leading, CGFloat(depth) * RemileControl.rowSpacing)

    }
}
