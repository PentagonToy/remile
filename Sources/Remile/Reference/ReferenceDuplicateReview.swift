import SwiftUI

struct ReferenceDuplicateReview: View {
    @ObservedObject var model: ReferenceModel
    let records: [ReferenceRecord]
    @StateObject private var state = Presentation()
    @Environment(\.dismiss) private var dismiss
    private final class Presentation: ObservableObject {
        @Published var preferred: UUID?
        @Published var align = false
        @Published var fields: [String: String] = [:]
    }
    private var ranked: [ReferenceRecord] { ReferenceMergePlan.ranked(records) }
    private var selected: ReferenceRecord? { records.first { $0.id == state.preferred } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge references").font(.title2.weight(.semibold))
            Picker("Base record", selection: $state.preferred) {
                ForEach(ranked) { record in
                    Text(ReferenceMergePlan.status(record) + " · " + record.citationKey + (record.id == ranked.first?.id ? " · Recommended" : "")).tag(Optional(record.id))
                }
            }
            if let selected {
                Text(ReferenceText.display(state.fields["title"] ?? selected.title)).font(RemileType.callout.weight(.medium)).lineLimit(2)
                Text([ReferenceColumn.publication.value(selected), selected.year, "\(Set(records.flatMap(\.attachments).map(\.sha256)).count) PDFs kept"].filter { !$0.isEmpty }.joined(separator: " · ")).font(RemileType.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Missing details are filled automatically.").font(RemileType.caption).foregroundStyle(.secondary)
                    ForEach(ReferenceMergePlan.conflicts(records), id: \.self) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(["doi": "DOI", "issn": "ISSN", "isbn": "ISBN", "url": "URL", "urldate": "Accessed", "journal": "Publication", "number": "Issue"][field] ?? field.capitalized).font(RemileType.caption).foregroundStyle(.secondary)
                            Picker(field, selection: Binding(get: { state.fields[field] ?? "" }, set: { state.fields[field] = $0 })) {
                                ForEach(Array(Set(records.compactMap { $0.fields[field] })).sorted(), id: \.self) { value in
                                    Text(ReferenceText.field(field, value) + " · " + ReferenceMergePlan.status(ranked.first { $0.fields[field] == value }!)).tag(value)
                                }
                            }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(.vertical, 4).scrollContentGutter()
            }
            if Set(records.map(\.library)).count > 1 { Toggle("Align metadata across libraries", isOn: $state.align) }
            Text("Extra entries are removed. PDFs are kept. Citation keys may change.").font(RemileType.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(RemileStyle.warning).font(RemileType.caption) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Merge") { if let id = state.preferred { model.merge(records, preferred: id, alignMetadata: state.align, resolvedFields: state.fields) { dismiss() } } }.disabled(state.preferred == nil || model.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580, height: 490).background(RemileStyle.background).tint(RemileStyle.accent)
            .onAppear { state.preferred = ranked.first?.id; prepare() }
            .onChange(of: state.preferred) { prepare() }
    }
    private func prepare() { if let id = state.preferred { state.fields = ReferenceMergePlan.fields(records, preferred: id) } }
}
