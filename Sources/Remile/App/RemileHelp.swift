import SwiftUI
import AppKit

enum RemileHints {
    static let overleafToken = "Create a Git authentication token."
    static let chatGPTPlan = "No separate API bill from remile. Your ChatGPT plan and credit settings apply."
    static func edits(_ shown: Bool) -> String { shown ? "Edit colours on · click to hide changes made by AI or an agent" : "Edit colours off · click to show changes made by AI or an agent" }
    static func history(_ shown: Bool) -> String { shown ? "Close local edit history" : "Compare with an earlier local version" }
    static func logs(_ shown: Bool) -> String { shown ? "Return to PDF preview" : "Show compiler errors, warnings and terminal output" }
}

private struct NativeToolTip: NSViewRepresentable {
    let text: String
    final class Surface: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    func makeNSView(context: Context) -> Surface { let view = Surface(); view.setAccessibilityElement(false); view.setAccessibilityHidden(true); view.toolTip = text; return view }
    func updateNSView(_ view: Surface, context: Context) { if view.toolTip != text { view.toolTip = text } }
}
/// All hover guidance uses the native macOS tooltip, including AppKit controls.
extension View {
    func remileHelp(_ text: String) -> some View { help(text).background(NativeToolTip(text: text)).accessibilityHint(text) }
}
