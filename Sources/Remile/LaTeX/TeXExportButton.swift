import SwiftUI
import AppKit

/// Draw in a fixed canvas so native menu-label padding cannot shift the icon.
struct TeXExportButton: NSViewRepresentable {
    @ObservedObject var project: TeXProject
    func makeCoordinator() -> Coordinator { Coordinator(project) }
    func makeNSView(context: Context) -> ExportButton {
        let button = ExportButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        button.title = ""; button.isBordered = false; button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator; button.action = #selector(Coordinator.openMenu(_:))
        button.setAccessibilityLabel("Export"); button.toolTip = "Export"
        return button
    }
    func updateNSView(_ button: ExportButton, context: Context) { context.coordinator.project = project; button.needsDisplay = true }
    final class ExportButton: NSButton {
        override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
        override var isFlipped: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            if isHighlighted { NSColor.labelColor.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill() }
            guard let symbol = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .heavy))?
                .withSymbolConfiguration(.init(paletteColors: [NSColor(RemileStyle.accent)])) else { return }
            symbol.isTemplate = false
            let size = symbol.size
            symbol.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 + 2.2, width: size.width, height: size.height))
        }
    }
    @MainActor final class Coordinator: NSObject {
        var project: TeXProject
        init(_ project: TeXProject) { self.project = project }
        @objc func openMenu(_ sender: NSButton) {
            let menu = NSMenu()
            let pdf = NSMenuItem(title: "PDF…", action: #selector(exportPDF), keyEquivalent: ""); pdf.target = self; pdf.isEnabled = project.pdf != nil
            let source = NSMenuItem(title: "Source (.zip)…", action: #selector(exportSource), keyEquivalent: ""); source.target = self
            menu.autoenablesItems = false; menu.addItem(pdf); menu.addItem(source)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
        }
        @objc private func exportPDF() { project.export() }
        @objc private func exportSource() { project.exportSource() }
    }
}
