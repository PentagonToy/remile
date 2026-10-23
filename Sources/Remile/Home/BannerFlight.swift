import SwiftUI

/// A brief pass on a mode change; never an idle animation or an online operation.
struct BannerFlight: View {
    @ObservedObject private var network = NetworkAccessState.shared
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @StateObject private var flight = Flight()
    private final class Flight: ObservableObject {
        @Published var departure: Date?
        var task: Task<Void, Never>?
        func stop() { task?.cancel(); task = nil; departure = nil }
        func start() {
            stop(); departure = Date()
            task = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(3.6)); self?.departure = nil; self?.task = nil } catch { }
            }
        }
        deinit { task?.cancel() }
    }
    var body: some View {
        GeometryReader { geometry in
            DecorativeTimeline(interval: 1.0 / 30, enabled: flight.departure != nil) { date, moves in
                if let departure = flight.departure, moves,
                   let image = RemileArtwork.image("airplane", dark: scheme == .dark) {
                    let progress = min(1, max(0, date.timeIntervalSince(departure) / 3.6))
                    let travel = network.offline ? 1 - progress : progress
                    let x = -60 + (geometry.size.width + 120) * travel
                    let baseline = geometry.size.height * 0.25
                    // A shallow arch clears the tall letters while keeping the visible plane below the border.
                    let lift = min(geometry.size.height * 0.16, max(0, baseline - 18))
                    let y = baseline - lift * sin(.pi * travel)
                    let tilt = atan(-lift * .pi * cos(.pi * travel) / (geometry.size.width + 120))
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 96, height: 96)
                        .scaleEffect(x: network.offline ? -1 : 1, y: 1)
                        .rotationEffect(.radians(tilt))
                        .position(x: x, y: y)
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
            .onChange(of: network.offline) { if animations && !reduceMotion { flight.start() } }
            .onChange(of: animations) { if !animations { flight.stop() } }
            .onChange(of: reduceMotion) { if reduceMotion { flight.stop() } }
            .onDisappear { flight.stop() }
    }
}
