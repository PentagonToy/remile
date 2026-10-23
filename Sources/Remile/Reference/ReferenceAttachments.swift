import SwiftUI

struct ReferenceAttachments: View {
    @ObservedObject var model: ReferenceModel
    let recordID: UUID
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var selected = Set<UUID>() }
    private var record: ReferenceRecord? { model.records.first { $0.id == recordID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Attachments").font(.title2.weight(.semibold))
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(record?.attachments ?? []) { file in
                        Toggle(isOn: Binding(get: { state.selected.contains(file.id) }, set: { if $0 { state.selected.insert(file.id) } else { state.selected.remove(file.id) } })) {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.richtext").foregroundStyle(RemileStyle.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(file.name).lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)).font(RemileType.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.toggleStyle(.checkbox).padding(12).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                    }
                }.scrollContentGutter()
            }
            Text("Remove from this reference. Original files stay unchanged.").font(RemileType.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button { if let record { model.removeAttachments(state.selected, from: record) { dismiss() } } } label: { Label("Remove selected", systemImage: "trash") }
                    .disabled(state.selected.isEmpty || model.busy).remileHelp("Remove selected attachments")
            }
        }.padding(24).frame(width: 480, height: 360).background(RemileStyle.background).tint(RemileStyle.accent)
    }
}
