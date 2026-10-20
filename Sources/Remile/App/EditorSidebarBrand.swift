import SwiftUI

struct EditorSidebarBrand: View {
    let compact: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = RemileArtwork.image(compact ? "banner" : "lighthouse", dark: scheme == .dark) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: compact ? 42 : 110).id(compact).transition(.opacity).accessibilityHidden(true)
            }
            if !compact {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Across time, a few words find you here.").font(.system(size: 18, weight: .regular, design: .serif)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    Text("— remile.").font(.system(size: 14, design: .serif)).foregroundStyle(RemileStyle.accent)
                }.padding(.horizontal, 4).padding(.bottom, 8).transition(.opacity)
            }
        }
    }
}
