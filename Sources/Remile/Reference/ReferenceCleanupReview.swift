import SwiftUI

struct ReferenceCleanupReview: View {
    @ObservedObject var model: ReferenceModel
    @ObservedObject private var network = NetworkAccessState.shared
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
        @Published var paper: ReferenceRecord?
        @Published var progress: String?
        var loaded = false
        var lookupTask: Task<Void, Never>?
    }
    private struct DuplicateGroup: Identifiable { let records: [ReferenceRecord]; var id: UUID { records[0].id } }
    private var missingPDFs: [ReferenceRecord] { model.libraryRecords.filter { $0.trashed == nil && $0.attachments.isEmpty } }
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
                Text("PDFs · \(missingPDFs.count)").tag(2)
            }.pickerStyle(.segmented).labelsHidden().disabled(state.loading) }
            if state.loading { VStack(spacing: 12) { ProgressView(); if let progress = state.progress { Text(progress).font(RemileType.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if state.tab == 0 && state.changes.isEmpty { empty("No metadata changes") }
            else if state.tab == 1 && duplicateGroups.isEmpty { empty("No duplicate candidates") }
            else if state.tab == 2 && missingPDFs.isEmpty { empty("Every reference has a PDF") }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if state.tab == 0 {
                            ForEach(state.changes) { change in metadata(change) }
                        } else if state.tab == 1 {
                            ForEach(duplicateGroups) { duplicate($0) }
                        } else {
                            ForEach(missingPDFs) { record in
                                HStack(spacing: 12) {
                                    Text(record.displayTitle).font(RemileType.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Find PDF…") { state.paper = record }.disabled(model.busy)
                                }.padding(12).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }.padding(.vertical, 4).scrollContentGutter()
                }.frame(maxHeight: .infinity)
            }
            if let error = state.error ?? model.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if state.progress != nil { Button("Stop") { state.lookupTask?.cancel() } }
                else if state.tab == 0 { Button(target == nil ? "Look up missing" : "Look up") { state.lookupTask = Task { await lookup() } }.disabled(state.loading || model.busy || network.offline).remileHelp("Find missing metadata and abstracts online. Review before applying.") }
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
            .sheet(item: $state.paper) { ReferencePaperSearch(model: model, target: $0) }
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
        let records = target.map { [$0] } ?? model.libraryRecords.filter(ReferenceCleanup.needsLookup)
        guard !records.isEmpty else { state.error = "No missing metadata to look up."; return }
        state.loading = true; state.error = nil
        state.progress = "Looking up 0 of \(records.count)…"
        defer { state.loading = false; state.progress = nil }
        do {
            var failed = 0
            for (index, record) in records.enumerated() {
                try Task.checkCancellation(); try NetworkAccess.requireOnline()
                state.progress = "Looking up \(index + 1) of \(records.count)…"
                do {
                    let local = state.changes.first(where: { $0.id == record.id })?.after ?? record
                    let fetched = try await ReferencePaperLookup.metadata(for: local)
                    try Task.checkCancellation(); try NetworkAccess.requireOnline()
                    if let change = try ReferenceCleanup.onlineChange(record, local: local, fetched: fetched) {
                        let existing = state.changes.firstIndex { $0.id == record.id }
                        if let existing { state.changes[existing] = change }
                        else { state.changes.append(change); state.included.insert(change.id) }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failed += 1 }
            }
            if failed > 0 { state.error = "Could not look up \(failed) of \(records.count) references." }
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
