import SwiftUI

struct RemileEditorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(RemileStyle.ink)
            .background(RemileStyle.surface.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: RemileRadius.control))
            .overlay(RoundedRectangle(cornerRadius: RemileRadius.control).stroke(.primary.opacity(0.08)))
    }
}

struct OverleafMark: View {
    var body: some View { SymbolIcon(systemName: "leaf").accessibilityHidden(true) }
}
