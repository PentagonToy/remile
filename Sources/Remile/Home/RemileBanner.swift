import SwiftUI

/// Flexible frame with independent vector artwork, so wide windows never stretch the wordmark.
struct RemileBanner: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.13))
                RoundedRectangle(cornerRadius: 1).inset(by: 4).strokeBorder(.primary.opacity(0.06))
                if let image = RemileArtwork.image("wordmark", dark: scheme == .dark) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: min(300, geometry.size.width * 0.46))
                }
                BannerBeacon()
                BannerFlight()
            }
        }.accessibilityLabel("remile.")
    }
}
