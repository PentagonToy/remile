import SwiftUI
import AppKit

/// The active scene supplies actions so menu commands never affect another window.
struct WorkspaceActions {
    var ask: (() -> Void)? = nil
    var references: (() -> Void)? = nil
    var restorePanes: (() -> Void)? = nil
    var logs: (() -> Void)? = nil
    var find: ((NSTextFinder.Action) -> Void)? = nil
    var complete: (() -> Void)? = nil
    var nextTab: (() -> Void)? = nil
    var previousTab: (() -> Void)? = nil
}
private struct WorkspaceActionsKey: FocusedValueKey { typealias Value = WorkspaceActions }
private struct PDFSlideActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var pdfSlideAction: (() -> Void)? {
        get { self[PDFSlideActionKey.self] }
        set { self[PDFSlideActionKey.self] = newValue }
    }
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}
struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceActions) private var actions
    @FocusedValue(\.pdfSlideAction) private var slideAction
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Slide View") { slideAction?() }.disabled(slideAction == nil)
        }
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find in Document…") { actions?.find?(.showFindInterface) }.keyboardShortcut("f")
                Button("Find Next") { actions?.find?(.nextMatch) }.keyboardShortcut("g")
                Button("Find Previous") { actions?.find?(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Find and Replace…") { actions?.find?(.showReplaceInterface) }.keyboardShortcut("f", modifiers: [.command, .option])
                Button("Use Selection for Find") { actions?.find?(.setSearchString) }.keyboardShortcut("e")
            }.disabled(actions?.find == nil)
            Button("Complete Command") { actions?.complete?() }.keyboardShortcut(.escape, modifiers: .option).disabled(actions?.complete == nil)
        }
        CommandMenu("Workspace") {
            Button("Next Source Tab") { actions?.nextTab?() }.keyboardShortcut(.tab, modifiers: .control).disabled(actions?.nextTab == nil)
            Button("Previous Source Tab") { actions?.previousTab?() }.keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(actions?.previousTab == nil)
            Divider()
            Button("Show or Hide Ask") { actions?.ask?() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(actions?.ask == nil)
            Button("Reference Library…") { actions?.references?() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(actions?.references == nil)
            Divider()
            Button("Restore Panes") { actions?.restorePanes?() }.disabled(actions?.restorePanes == nil)
            Button("Show Logs or PDF") { actions?.logs?() }.disabled(actions?.logs == nil)
        }
    }
}
struct WorkspaceAskButton: View {
    @AppStorage("assistant.provider") private var provider = "Apple Intelligence"
    let isPresented: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { SymbolLabel("Ask", systemImage: isPresented ? "text.bubble.fill" : "text.bubble") }
            .labelStyle(.iconOnly).foregroundStyle(isPresented ? RemileStyle.accent : RemileStyle.ink)
            .accessibilityLabel("Ask").accessibilityValue(isPresented ? "Open" : "Closed").remileHelp(provider == "Off" ? "AI is off. Open Ask to view history or choose AI." : "Ask about this document · ⇧⌘A")
    }
}
struct WorkspaceReferenceButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { SymbolLabel("Reference library", systemImage: "books.vertical") }
            .labelStyle(.iconOnly).accessibilityLabel("Reference library").remileHelp("Reference library · ⇧⌘R")
    }
}
