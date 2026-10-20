import SwiftUI

struct InlineName: View {
    let value: String
    @Binding var editing: Bool
    let rename: (String) -> Bool
    @StateObject private var draft = Draft()
    private final class Draft: ObservableObject { @Published var text = "" }
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            if editing {
                TextField("Name", text: $draft.text).textFieldStyle(.plain).focused($focused)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                    .overlay(RoundedRectangle(cornerRadius: RemileRadius.control).stroke(Color(nsColor: RemileStyle.navy)))
                    .onAppear { draft.text = value; focused = true }
                    .onSubmit { if rename(draft.text) { editing = false } }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { if !focused { editing = false } }
            } else {
                Text(value).lineLimit(1).truncationMode(.middle).onTapGesture(count: 2) { draft.text = value; editing = true }
            }
        }.remileHelp("Double-click to rename · Return applies · Escape cancels")
    }
}
