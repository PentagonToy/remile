import SwiftUI

struct InlineName: View {
    let value: String
    @Binding var editing: Bool
    let rename: (String) -> Bool
    var truncation: Text.TruncationMode = .middle
    @StateObject private var draft = Draft()
    private final class Draft: ObservableObject { @Published var text = ""; var finished = true; var original = ""; var apply: ((String) -> Bool)? }
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            if editing {
                TextField("Name", text: $draft.text).textFieldStyle(.plain).focused($focused)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                    .overlay(RoundedRectangle(cornerRadius: RemileRadius.control).stroke(Color(nsColor: RemileStyle.navy)))
                    .background(InlineEditBoundary(cancel: { draft.finished = true; editing = false }) { commit() })
                    .onAppear { draft.text = value; draft.original = value; draft.apply = rename; draft.finished = false; focused = true }
                    .onSubmit { commit() }
                    .onExitCommand { draft.finished = true; editing = false }
                    .onDisappear { commit() }
            } else {
                Text(value).lineLimit(1).truncationMode(truncation).onTapGesture(count: 2) { draft.text = value; editing = true }
                    .accessibilityAction(named: "Rename") { draft.text = value; editing = true }
            }
        }.remileHelp("Double-click to rename · Return or click elsewhere to save · Esc cancels")
    }
    private func commit() {
        guard !draft.finished else { return }
        draft.finished = true
        if InlineNamePolicy.isEmpty(draft.text) { editing = false; return }
        if draft.text == draft.original || draft.apply?(draft.text) == true { editing = false }
        else { draft.finished = false; focused = true }
    }
}
