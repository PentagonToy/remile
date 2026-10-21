import SwiftUI

struct EditorSidebarBrand: View {
    let compact: Bool
    @AppStorage("editor.sidebarArtwork") private var visible = true
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if visible { VStack(alignment: .leading, spacing: 10) {
            if let image = RemileArtwork.image(compact ? "banner" : "lighthouse", dark: scheme == .dark) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: compact ? 42 : 110).id(compact).transition(.opacity).accessibilityHidden(true)
            }
            if !compact {
                VStack(alignment: .leading, spacing: 10) {
                    Text(RemileBrand.tagline).font(.system(size: 18, weight: .regular, design: .serif)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    Text("— remile.").font(.system(size: 14, design: .serif)).foregroundStyle(RemileStyle.accent)
                }.padding(.horizontal, 4).padding(.bottom, 8).transition(.opacity)
            }
        } }
    }
}

struct EditorSidebarFooter: View {
    let compact: Bool
    let title: String
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorSidebarBrand(compact: compact)
            Button(action: action) {
                Label(title, systemImage: "gearshape").font(RemileType.callout).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(RemileToolStyle())
        }.padding(12)
    }
}
