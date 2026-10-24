import SwiftUI

/// Catalogue work happens only after opening this picker or explicitly saving.
struct ReferenceSaveButton: View {
    let source: URL
    @StateObject private var state = State()
    @AppStorage("reference.collect.library") private var remembered = ReferenceLibrary.primaryID.uuidString
    @MainActor private final class State: ObservableObject {
        @Published var presented = false
        @Published var libraries: [ReferenceLibrary] = []
        @Published var library = ReferenceLibrary.primaryID
        @Published var busy = false
        @Published var saved = false
        @Published var message: String?
    }
    var body: some View {
        Button { state.presented.toggle() } label: { Label(state.saved ? "Saved" : "Save reference", systemImage: state.saved ? "checkmark" : "text.book.closed") }
            .fixedSize().remileHelp("Save this PDF to a Reference library")
            .sheet(isPresented: $state.presented) {
                ReferenceSavePanel(filename: source.lastPathComponent, libraries: state.libraries, library: $state.library, busy: state.busy, message: state.message, cancel: { state.presented = false }, save: save)
                    .interactiveDismissDisabled(state.busy)
                    .task {
                        do {
                            let libraries = try await Task.detached(priority: .userInitiated) { try ReferenceRepository().libraries().filter { $0.trashed == nil } }.value
                            state.libraries = libraries
                            state.library = libraries.first { $0.id.uuidString == remembered }?.id ?? libraries.first?.id ?? ReferenceLibrary.primaryID
                        } catch { state.message = error.localizedDescription }
                    }
            }
    }
    private func save() {
        guard !state.busy else { return }
        state.busy = true; state.message = nil
        let library = state.library
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try ReferenceCollect.save(source, library: library) }.value
                remembered = library.uuidString; state.saved = true; state.presented = false
            } catch { state.message = error.localizedDescription }
            state.busy = false
        }
    }
}
