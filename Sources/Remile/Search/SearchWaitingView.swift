import SwiftUI

struct SearchWaitingView: View {
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var startedAt = Date()
    var body: some View {
        VStack(spacing: 14) {
            RemileLighthouse().frame(width: 230, height: 90)
            if animations && !reduceMotion { ProgressView().progressViewStyle(.linear) }
            else { ProgressView(value: 0.35).progressViewStyle(.linear) }
            Text("Somewhere in these pages, a few words are waiting…")
                .font(RemileType.callout).lineLimit(1).minimumScaleFactor(0.75)
            TimelineView(.periodic(from: startedAt, by: 0.1)) { tick in
                Text("\(max(0, tick.date.timeIntervalSince(startedAt)), specifier: "%.1f") s elapsed")
                    .font(RemileType.caption).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }.frame(maxWidth: 460).padding(24).accessibilityElement(children: .combine)
            .accessibilityLabel("Somewhere in these pages, a few words are waiting…")
    }
}
