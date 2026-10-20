import SwiftUI

struct ReaderPageControl: View {
    let current: Int
    let total: Int
    let go: (Int) -> Void
    @StateObject private var state = EntryState()
    private final class EntryState: ObservableObject { @Published var text = "" }
    @FocusState private var editing: Bool
    var body: some View {
        HStack(spacing: 6) {
            TextField("Page", text: $state.text)
                .textFieldStyle(.plain).multilineTextAlignment(.center)
                .padding(.horizontal, 6).frame(width: 44, height: 28)
                .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(RemileStyle.ink.opacity(editing ? 0.6 : 0.25)))
                .focused($editing).accessibilityLabel("Current page").help("Enter a page number and press Return")
                .onSubmit(commit)
                .onExitCommand { state.text = String(current); editing = false }
            Text("/ \(total)").fixedSize()
        }.font(RemileType.callout).monospacedDigit().disabled(total == 0)
            .onAppear { state.text = String(current) }
            .onChange(of: current) { if !editing { state.text = String(current) } }
            .onChange(of: editing) { if !editing { state.text = String(current) } }
    }
    private func commit() {
        let value = state.text.trimmingCharacters(in: .whitespaces)
        if let number = Int(value), number >= 1, number <= total { go(number) }
        state.text = String(current); editing = false
    }
}
