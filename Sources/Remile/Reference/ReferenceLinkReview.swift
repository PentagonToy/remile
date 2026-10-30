import SwiftUI

/// Connections retain each source record, PDF and citation key independently.
struct ReferenceLinkReview: View {
    @ObservedObject var model: ReferenceModel
    let library: ReferenceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: UUID?
    @State private var targetID: UUID?
    @State private var query = ""
    private var sources: [ReferenceRecord] { model.contents(library.id).filter { $0.trashed == nil && $0.remarkable != nil } }
    private var source: ReferenceRecord? { sources.first { $0.id == sourceID } }
    private var targets: [ReferenceRecord] {
        guard let source else { return [] }
        let eligible = Set(model.activeLibraries.filter { $0.source != "remarkable" }.map(\.id))
        let candidates = model.allRecords.filter { record in
            record.remarkable == nil && eligible.contains(record.library) &&
            (query.isEmpty || record.searchText.localizedCaseInsensitiveContains(query))
        }
        let matches = Set(candidates.filter { ReferenceLinkMatch.reason(source, $0) != nil }.map(\.id))
        return candidates.sorted {
            let lhs = matches.contains($0.id)
            let rhs = matches.contains($1.id)
            return lhs != rhs ? lhs : $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RemileControl.rowSpacing) {
            HStack { Text("Connect to Libraries").font(RemileType.heading); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy) }
            HStack(spacing: 0) {
                List(sources, selection: $sourceID) { record in
                    Text(record.displayTitle).lineLimit(3).padding(.vertical, RemileControl.spacing).tag(record.id)
                }.listStyle(.plain).frame(width: 280)
                Divider()
                VStack(alignment: .leading) {
                    TextField("Find a reference", text: $query).textFieldStyle(.roundedBorder)
                    List(targets, selection: $targetID) { record in
                        VStack(alignment: .leading, spacing: RemileControl.spacing) {
                            Text(record.displayTitle).lineLimit(3)
                            Text(model.libraries.first(where: { $0.id == record.library })?.name ?? "")
                                .font(RemileType.caption).foregroundStyle(.secondary)
                            if let source, let reason = ReferenceLinkMatch.reason(source, record) {
                                Text(reason).font(RemileType.caption).foregroundStyle(RemileStyle.accent)
                            }
                            if source?.linkedReferences?.contains(record.id) == true {
                                Text("Connected").font(RemileType.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, RemileControl.spacing).tag(record.id)
                    }.listStyle(.plain)
                }.padding(.leading, RemileControl.rowSpacing)
            }.frame(height: 390)
            if let error = model.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
            HStack {
                Spacer()
                if let source, let target = targets.first(where: { $0.id == targetID }) {
                    let connected = source.linkedReferences?.contains(target.id) == true
                    Button(connected ? "Disconnect" : "Connect") { model.connectRemarkable(source, to: target, disconnect: connected) }.disabled(model.busy)
                }
            }
        }.padding(RemileControl.rowSpacing * 2).frame(width: 820)
            .background(RemileStyle.background).tint(RemileStyle.accent).interactiveDismissDisabled(model.busy)
            .onAppear { sourceID = sources.first?.id }
            .onChange(of: sourceID) { _, _ in targetID = nil }
    }
}

enum ReferenceLinkMatch {
    static func reason(_ source: ReferenceRecord, _ target: ReferenceRecord) -> String? {
        for field in ["doi", "url"] {
            let doi = ReferenceDuplicates.normaliseDOI(source.fields[field] ?? "")
            if doi.hasPrefix("10."), doi.contains("/"), [target.fields["doi"], target.fields["url"]].compactMap({ $0 }).contains(where: { ReferenceDuplicates.normaliseDOI($0) == doi }) { return "Same DOI" }
        }
        let hashes = Set(source.attachments.map(\.sha256))
        if target.attachments.contains(where: { hashes.contains($0.sha256) }) { return "Same PDF" }
        return ReferenceDuplicates.lookup([source, target])[source.id] != nil ? "Similar reference" : nil
    }
}
