import AppKit

/// Keep macOS momentum/trackpad physics; configure elasticity instead of synthesising input.
enum ReaderScrolling {
    static let preference = "reader.elasticScrolling"
    static func configure(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            let enabled = UserDefaults.standard.object(forKey: preference) as? Bool ?? true
            scroll.verticalScrollElasticity = enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .allowed : .none
            scroll.horizontalScrollElasticity = .none
            scroll.usesPredominantAxisScrolling = true
        }
        for child in view.subviews { configure(child) }
    }
}
