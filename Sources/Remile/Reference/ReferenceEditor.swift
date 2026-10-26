import SwiftUI

struct ReferenceEditor: View {
    @ObservedObject var model: ReferenceModel
    let existing: Bool
    @StateObject private var state: Presentation
    private final class Presentation: ObservableObject {
        @Published var draft: ReferenceRecord
        @Published var citation: String
        @Published var citationMode: Bool
        @Published var error: String?
        init(record: ReferenceRecord?, citation: String) { draft = record ?? ReferenceRecord(); self.citation = citation; citationMode = !citation.isEmpty }
    }
    @Environment(\.dismiss) private var dismiss
    init(model: ReferenceModel, record: ReferenceRecord? = nil, citation: String = "") {
        self.model = model; existing = record != nil
        _state = StateObject(wrappedValue: Presentation(record: record, citation: citation))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(existing ? "Edit reference" : "Add reference").font(.title2.weight(.semibold)); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            Picker("Entry", selection: $state.citationMode) { Text("Details").tag(false); Text("BibTeX").tag(true) }.pickerStyle(.segmented).labelsHidden()
            if state.citationMode {
                TextEditor(text: $state.citation).font(.system(size: 13, design: .monospaced)).frame(minHeight: 250).scrollContentBackground(.hidden).padding(8).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                Text("Paste one BibTeX entry.").font(RemileType.caption).foregroundStyle(.secondary)
            } else {
                ScrollView { Form {
                    TextField("Title", text: field("title"))
                    TextField("Authors", text: field("author"), prompt: Text("Separate names with and"))
                    TextField("Year", text: field("year"))
                    LabeledContent("Citation key", value: existing ? state.draft.citationKey : ReferenceKeyRule.current.key(for: state.draft)).font(RemileType.caption)
                    TextField("Journal / book", text: field("journal"))
                    DisclosureGroup("Publication details") {
                        ForEach(["publisher", "booktitle", "editor", "date", "volume", "number", "pages", "edition", "series", "address", "institution", "organization"], id: \.self) { name in
                            TextField(["number": "Issue", "booktitle": "Book / proceedings", "address": "Place", "organization": "Organisation" ][name] ?? name.capitalized, text: field(name))
                        }
                    }
                    DisclosureGroup("Identifiers and details") {
                        ForEach(["isbn", "issn", "pmid", "pmcid", "urldate", "language", "keywords", "license"], id: \.self) { name in
                            TextField(["isbn": "ISBN", "issn": "ISSN", "pmid": "PMID", "pmcid": "PMCID", "urldate": "Accessed", "license": "Licence"][name] ?? name.capitalized, text: field(name))
                        }
                    }
                    TextField("DOI", text: field("doi"))
                    TextField("URL", text: field("url"))
                    TextField("Abstract", text: field("abstract"), axis: .vertical).lineLimit(3...8)
                    TextField("Notes", text: field("note"), axis: .vertical).lineLimit(2...4)
                    Picker("Type", selection: Binding(get: { ReferenceKind.classify(state.draft) }, set: { state.draft = $0.applying(to: state.draft) })) {
                        ForEach(ReferenceKind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
                    }
                    if ReferenceKind.classify(state.draft) == .other { TextField("BibTeX type", text: $state.draft.type) }
                }.textFieldStyle(.roundedBorder) }.frame(maxHeight: 430)
            }
            if let error = state.error { Text(error).foregroundStyle(RemileStyle.warning).font(RemileType.callout) }
            if let error = model.error { Text(error).foregroundStyle(RemileStyle.warning).font(RemileType.callout) }
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }.padding(24).frame(width: 560).background(RemileStyle.background).tint(RemileStyle.accent)
    }
    private func field(_ name: String) -> Binding<String> { Binding(get: { state.draft.fields[name] ?? "" }, set: { state.draft.fields[name] = $0 }) }
    private func save() {
        do {
            if state.citationMode {
                let records = try ReferenceBibTeX.parse(state.citation)
                guard records.count == 1 else { throw ReferenceFailure("Use Import files to add a bibliography with several entries.") }
                state.draft.fields = records[0].fields; state.draft.key = records[0].key; state.draft.type = records[0].type; state.draft.originalCitation = state.citation
            }
            guard !state.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state.draft.fields["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw ReferenceFailure("Add a title before saving.") }
            _ = try ReferenceBibTeX.export([state.draft]); state.error = nil
            model.save(state.draft, existing: existing, onSaved: { dismiss() })
        } catch { state.error = error.localizedDescription }
    }
}
