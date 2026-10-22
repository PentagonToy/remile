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
    private static let symbol: NSImage? = {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let urls = [Bundle.main.resourceURL?.appendingPathComponent("Brand/overleaf-mark.svg"), source.appendingPathComponent("others/symbols/integrations/overleaf-mark.svg")]
        guard let image = urls.compactMap({ $0 }).compactMap({ NSImage(contentsOf: $0) }).first else { return nil }
        image.isTemplate = true; return image
    }()
    var body: some View {
        if let image = Self.symbol { Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18).accessibilityHidden(true) }
        else { Image(systemName: "leaf").accessibilityHidden(true) }
    }
}
