import SwiftUI
import AppKit

struct RemileOption: Equatable {
    var id: String
    var title: String
    var sample: String? = nil
    var font: String? = nil
    var separator = false

    var attributedTitle: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 28)]
        return NSAttributedString(string: sample.map { $0 + "\t" + title } ?? title, attributes: [.font: font.flatMap { NSFont(name: $0, size: 14) } ?? NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph])
    }
}

/// Native pop-up menus provide compact rows, selection checks and keyboard dismissal.
struct RemileOptionPicker: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var options: [RemileOption]
    var selected: String
    var label: String
    var select: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false; button.bezelStyle = .rounded; button.controlSize = .small
        button.font = .systemFont(ofSize: 14); button.contentTintColor = NSColor(RemileStyle.ink)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        if coordinator.options != options {
            let menu = NSMenu(); menu.autoenablesItems = false
            for option in options {
                if option.separator { menu.addItem(.separator()) }
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.attributedTitle = option.attributedTitle; item.representedObject = option.id
                menu.addItem(item)
            }
            button.menu = menu; coordinator.options = options
        }
        if let item = button.itemArray.first(where: { $0.representedObject as? String == selected }) { button.select(item) }
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label); button.toolTip = label
    }
    final class Coordinator: NSObject {
        var parent: RemileOptionPicker
        var options: [RemileOption] = []
        init(_ parent: RemileOptionPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            parent.select(value)
        }
    }
}
