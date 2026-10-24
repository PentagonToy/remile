import SwiftUI

struct WriterLaTeXSheet: View {
    @Binding var source: String
    let cancel: () -> Void
    let insert: (String) -> Void
    @FocusState private var editing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LaTeX").font(RemileType.heading)
            TextEditor(text: $source).font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden).focused($editing).accessibilityLabel("LaTeX source")
                .frame(maxWidth: .infinity).frame(height: 120).padding(8)
                .background(RemileStyle.sidebar, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RemileStyle.ink.opacity(0.15)))
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Insert") { insert(source) }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 440).background(RemileStyle.background).tint(RemileStyle.accent)
            .onAppear { editing = true }
    }
}
