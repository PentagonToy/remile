import SwiftUI

/// A single lightweight beam shared by Home and the search waiting view.
struct RemileLighthouse: View {
    @Environment(\.colorScheme) private var scheme
    var aim: Double? = nil
    var body: some View {
        DecorativeTimeline(enabled: aim == nil) { date, moves in
            ZStack {
                Canvas { context, size in
                    let phase = aim ?? (moves ? sin(date.timeIntervalSinceReferenceDate * .pi / 2.4) : 0)
                    let lamp = CGPoint(x: size.width * 193 / 310, y: size.height * 46 / 120)
                    let centre = size.height * (0.38 + 0.28 * phase)
                    let spread = size.height * 0.20
                    var beam = Path()
                    beam.move(to: lamp)
                    beam.addLine(to: CGPoint(x: 0, y: centre - spread))
                    beam.addLine(to: CGPoint(x: 0, y: centre + spread))
                    beam.closeSubpath()
                    context.fill(beam, with: .linearGradient(Gradient(colors: [RemileStyle.accent.opacity(0), RemileStyle.accent.opacity(0.27)]), startPoint: CGPoint(x: 0, y: centre), endPoint: lamp))
                    context.fill(Path(ellipseIn: CGRect(x: lamp.x - 2.5, y: lamp.y - 2.5, width: 5, height: 5)), with: .color(RemileStyle.accent.opacity(0.8)))
                }
                if let image = RemileArtwork.image("lighthouse", dark: scheme == .dark) {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            }
        }.aspectRatio(310.0 / 120, contentMode: .fit).clipped().accessibilityHidden(true)
    }
}
