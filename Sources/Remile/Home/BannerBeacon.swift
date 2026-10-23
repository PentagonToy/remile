import SwiftUI

/// Draw the beam in banner coordinates, independently of the small tower artwork.
struct BannerBeacon: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let width = min(190, geometry.size.width * 0.24)
            let height = width * 120 / 310
            let left = geometry.size.width - width - 20
            let top = geometry.size.height - height - 12
            let lamp = CGPoint(x: left + width * 193 / 310, y: top + height * 46 / 120)
            // Repaint only the beam's bounds, independently of the wordmark and tower.
            let reach = min(lamp.x - 10, geometry.size.width / 2 + min(300, geometry.size.width * 0.46) * 0.43 + 4)
            DecorativeTimeline { date, moves in
                Canvas { context, size in
                    let phase = moves ? sin(date.timeIntervalSinceReferenceDate * .pi / 3.6) : 0
                    let centre = size.height / 2 + height * 0.24 * phase
                    var beam = Path()
                    beam.move(to: CGPoint(x: size.width, y: size.height / 2))
                    beam.addLine(to: CGPoint(x: 0, y: centre - height * 0.27))
                    beam.addLine(to: CGPoint(x: 0, y: centre + height * 0.27))
                    beam.closeSubpath()
                    context.fill(beam, with: .linearGradient(Gradient(colors: [RemileStyle.accent.opacity(0), RemileStyle.accent.opacity(0.13)]), startPoint: CGPoint(x: 0, y: centre), endPoint: CGPoint(x: size.width, y: size.height / 2)))
                }
            }.frame(width: max(10, lamp.x - reach), height: height * 1.04).position(x: (reach + lamp.x) / 2, y: lamp.y)
            if let image = RemileArtwork.image("lighthouse", dark: scheme == .dark) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: width, height: height).position(x: left + width / 2, y: top + height / 2)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
