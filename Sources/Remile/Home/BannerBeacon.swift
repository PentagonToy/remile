import SwiftUI

/// Draw the beam in banner coordinates, independently of the small tower artwork.
struct BannerBeacon: View {
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let width = min(190, geometry.size.width * 0.24)
            let height = width * 120 / 310
            let left = geometry.size.width - width - 20
            let top = geometry.size.height - height - 12
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animations || reduceMotion)) { tick in
                Canvas { context, size in
                    let phase = animations && !reduceMotion ? sin(tick.date.timeIntervalSinceReferenceDate * .pi / 3.6) : 0
                    let lamp = CGPoint(x: left + width * 193 / 310, y: top + height * 46 / 120)
                    // The wordmark's period is near its right edge; fade out just beyond it.
                    let reach = size.width / 2 + min(300, size.width * 0.46) * 0.43 + 4
                    let centre = lamp.y + height * 0.24 * phase
                    var beam = Path()
                    beam.move(to: lamp)
                    beam.addLine(to: CGPoint(x: min(lamp.x - 10, reach), y: centre - height * 0.27))
                    beam.addLine(to: CGPoint(x: min(lamp.x - 10, reach), y: centre + height * 0.27))
                    beam.closeSubpath()
                    context.fill(beam, with: .linearGradient(Gradient(colors: [RemileStyle.accent.opacity(0), RemileStyle.accent.opacity(0.13)]), startPoint: CGPoint(x: reach, y: centre), endPoint: lamp))
                }
            }
            if let image = RemileArtwork.image("lighthouse", dark: scheme == .dark) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: width, height: height).position(x: left + width / 2, y: top + height / 2)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
