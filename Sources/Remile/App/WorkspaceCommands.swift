import SwiftUI

/// The active scene supplies actions so menu commands never affect another window.
struct WorkspaceActions {
    var ask: (() -> Void)? = nil
    var references: (() -> Void)? = nil
    var restorePanes: (() -> Void)? = nil
    var logs: (() -> Void)? = nil
}
private struct WorkspaceActionsKey: FocusedValueKey { typealias Value = WorkspaceActions }
extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}
struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceActions) private var actions
    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Show or Hide Ask") { actions?.ask?() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(actions?.ask == nil)
            Button("Reference Library…") { actions?.references?() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(actions?.references == nil)
            Divider()
            Button("Restore Panes") { actions?.restorePanes?() }.disabled(actions?.restorePanes == nil)
            Button("Show Logs or PDF") { actions?.logs?() }.disabled(actions?.logs == nil)
        }
    }
}
struct WorkspaceAskButton: View {
    let isPresented: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { SymbolLabel("Ask", systemImage: isPresented ? "text.bubble.fill" : "text.bubble") }
            .labelStyle(.iconOnly).foregroundStyle(isPresented ? RemileStyle.accent : RemileStyle.ink)
            .accessibilityLabel("Ask").accessibilityValue(isPresented ? "Open" : "Closed").remileHelp("Ask about this document · ⇧⌘A")
    }
}
struct WorkspaceReferenceButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { SymbolLabel("Reference library", systemImage: "books.vertical") }
            .labelStyle(.iconOnly).accessibilityLabel("Reference library").remileHelp("Reference library · ⇧⌘R")
    }
}
