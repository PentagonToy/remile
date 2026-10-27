import SwiftUI

struct ReferenceSavePanel: View {
    let filename: String
    let libraries: [ReferenceLibrary]
    @Binding var library: UUID
    var busy: Bool
    var message: String?
    var cancel: () -> Void
    var save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                SymbolIcon(systemName: "text.book.closed").foregroundStyle(RemileStyle.accent)
                Text("Save reference").font(RemileType.heading)
            }
            Text(filename).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(2).remileHelp(filename)
            VStack(alignment: .leading, spacing: 7) {
                Text("Library").font(RemileType.caption).foregroundStyle(.secondary)
                RemileOptionPicker(options: libraries.map { RemileOption(id: $0.id.uuidString, title: $0.name) }, selected: library.uuidString, label: "Reference library") { value in
                    if let id = UUID(uuidString: value) { library = id }
                }.padding(.horizontal, 6).frame(height: 30)
                    .background(RemileStyle.editorBar, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                    .disabled(busy || libraries.isEmpty)
            }
            if let message { Text(message).font(RemileType.caption).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(busy)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(busy || libraries.isEmpty)
            }
        }.padding(22).frame(width: 360).background(RemileStyle.background).tint(RemileStyle.accent)
    }
}
