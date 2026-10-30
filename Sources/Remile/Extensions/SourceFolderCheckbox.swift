import SwiftUI

struct SourceFolderCheckbox: NSViewRepresentable {
    let state: NSControl.StateValue
    let label: String
    let enabled: Bool
    let change: (Bool) -> Void
    final class Coordinator: NSObject {
        var change: (Bool) -> Void = { _ in }
        var state: NSControl.StateValue = .off
        @objc func click(_ sender: NSButton) { change(state != .on) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.click(_:)))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.change = change; context.coordinator.state = state
        button.state = state; button.isEnabled = enabled; button.setAccessibilityLabel(label)
    }
}
