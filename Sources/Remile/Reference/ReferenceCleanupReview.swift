import SwiftUI

struct ReferenceCleanupReview: View {
    @ObservedObject var model: ReferenceModel
    var target: ReferenceRecord? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject {
        @Published var changes: [ReferenceCleanup.Change] = []
        @Published var included = Set<UUID>()
        @Published var expanded = Set<UUID>()
        @Published var tab = 0
        @Published var loading = true
        @Published var error: String?
        @Published var group: DuplicateGroup?
        var loaded = false
        var lookupTask: Task<Void, Never>?
    }
    private struct DuplicateGroup: Identifiable { let records: [ReferenceRecord]; var id: UUID { records[0].id } }
    private var duplicateGroups: [DuplicateGroup] {
        let visible = Set(model.libraryRecords.filter { $0.trashed == nil }.map(\.id))
        let groups = Set(visible.compactMap { model.duplicates[$0]?.sorted { $0.uuidString < $1.uuidString } })
        let records = Dictionary(uniqueKeysWithValues: model.records.map { ($0.id, $0) })
        return groups.compactMap { ids -> DuplicateGroup? in
            let found = ids.compactMap { records[$0] }
            return found.count > 1 ? DuplicateGroup(records: found) : nil
        }.sorted { $0.records[0].displayTitle.localizedStandardCompare($1.records[0].displayTitle) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(target == nil ? "Clean up library" : "Review metadata").font(.title2.weight(.semibold))
            if target == nil { Picker("Review", selection: $state.tab) {
                Text("Metadata · \(state.changes.count)").tag(0)
                Text("Duplicates · \(duplicateGroups.count)").tag(1)
            }.pickerStyle(.segmented).labelsHidden() }
            if state.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if state.tab == 0 && state.changes.isEmpty { empty("No metadata changes") }
            else if state.tab != 0 && duplicateGroups.isEmpty { empty("No duplicate candidates") }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if state.tab == 0 {
                            ForEach(state.changes) { change in metadata(change) }
                        } else {
                            ForEach(duplicateGroups) { duplicate($0) }
                        }
                    }.padding(.vertical, 4).scrollContentGutter()
                }.frame(maxHeight: .infinity)
            }
            if let error = state.error ?? model.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if target != nil { Button("Look up") { state.lookupTask = Task { await lookup() } }.disabled(state.loading || model.busy).remileHelp("Look up DOI or arXiv metadata without AI") }
                Spacer()
                if state.tab == 0 {
                    Button("Apply selected") { model.applyCleanup(state.changes.filter { state.included.contains($0.id) }) { dismiss() } }
                        .disabled(state.loading || state.included.isEmpty || model.busy).keyboardShortcut(.defaultAction)
                        .remileHelp("Apply checked metadata changes. Citation keys stay unchanged.")
                }
            }
        }.padding(24).frame(width: 580, height: 430).background(RemileStyle.background).tint(RemileStyle.accent)
            .task { await refresh() }
            .onDisappear { state.lookupTask?.cancel() }
            .sheet(item: $state.group, onDismiss: { Task { await refresh() } }) { group in ReferenceDuplicateReview(model: model, records: group.records) }
    }
    private func metadata(_ change: ReferenceCleanup.Change) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Include " + change.before.displayTitle, isOn: Binding(get: { state.included.contains(change.id) }, set: { if $0 { state.included.insert(change.id) } else { state.included.remove(change.id) } }))
                .labelsHidden().toggleStyle(.checkbox).padding(.top, 3)
            DisclosureGroup(isExpanded: Binding(get: { state.expanded.contains(change.id) }, set: { if $0 { state.expanded.insert(change.id) } else { state.expanded.remove(change.id) } })) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(change.fields, id: \.self) { field in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(field == "@type" ? "TYPE" : field.uppercased()).font(RemileType.small).foregroundStyle(.secondary)
                            if let old = (field == "@type" ? change.before.type : change.before.fields[field]), !old.isEmpty { Text(old).foregroundStyle(.secondary) }
                            Text(field == "@type" ? change.after.type : (change.after.fields[field] ?? "")).textSelection(.enabled)
                        }.font(RemileType.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(change.before.displayTitle).font(RemileType.callout.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text(change.fields.map { $0 == "@type" ? "Type" : $0 == "doi" ? "DOI" : $0.capitalized }.joined(separator: " · ")).font(RemileType.caption).foregroundStyle(.secondary)
                }.remileHelp(change.before.displayTitle)
            }
        }.padding(14).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 7))
    }
    private func duplicate(_ group: DuplicateGroup) -> some View {
        let first = group.records[0]
        return Button { state.group = group } label: {
            HStack(spacing: 14) {
                Image(systemName: "doc.on.doc").foregroundStyle(RemileStyle.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text(first.displayTitle).font(RemileType.callout.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(group.records.count) references · " + [first.shortContributors, first.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(RemileType.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(RemileType.caption).foregroundStyle(.secondary)
            }.padding(14).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).remileHelp("Review duplicates: " + first.displayTitle).accessibilityLabel("Review duplicates: " + first.displayTitle)
    }
    private func empty(_ text: String) -> some View {
        VStack(spacing: 10) { Image(systemName: "checkmark.circle").font(.system(size: 24, weight: .light)).foregroundStyle(RemileStyle.accent); Text(text).font(RemileType.callout).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @MainActor private func lookup() async {
        guard let target else { return }
        state.loading = true; state.error = nil
        defer { state.loading = false }
        do {
            let local = state.changes.first?.after ?? target
            let fetched = try await ReferencePaperLookup.metadata(for: local)
            try Task.checkCancellation()
            var next = local; next.type = fetched.type
            next.fields.merge(fetched.fields) { _, verified in verified }
            state.changes = next.fields == target.fields && next.type == target.type ? [] : [.init(before: target, after: next)]
            state.included = Set(state.changes.map(\.id))
        } catch is CancellationError { }
        catch { state.error = error.localizedDescription }
    }
    @MainActor private func refresh() async {
        let records = target.map { [$0] } ?? model.libraryRecords.filter { $0.trashed == nil }, repository = model.repository
        do {
            let changes = try await Task.detached(priority: .userInitiated) { try ReferenceCleanup.proposals(records, repository: repository) }.value
            state.changes = changes
            let ids = Set(changes.map(\.id))
            if state.loaded { state.included.formIntersection(ids) }
            else { state.included = ids; if target == nil && changes.isEmpty && !duplicateGroups.isEmpty { state.tab = 1 } }
            state.loaded = true
        } catch { state.error = error.localizedDescription }
        state.loading = false
    }
}
