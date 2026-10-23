import SwiftUI

@MainActor enum DecorativeMotionDiagnostics {
    private(set) static var ticks: UInt64 = 0
    static func rendered() { ticks &+= 1 }
}

/// A bounded clock for slow artwork. No display link, polling or inactive-window timer.
struct DecorativeTimeline<Content: View>: View {
    var interval: TimeInterval = 1.0 / 12
    var enabled = true
    @ViewBuilder let content: (Date, Bool) -> Content
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @Environment(\.controlActiveState) private var focus
    @StateObject private var clock = Clock()
    @MainActor private final class Clock: ObservableObject {
        @Published var date = Date()
        private var timer: Timer?
        func run(_ enabled: Bool, interval: TimeInterval) {
            guard enabled else { stop(); return }
            guard timer == nil else { return }
            date = Date()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    DecorativeMotionDiagnostics.rendered(); self.date = Date()
                }
            }
            timer.tolerance = interval * 0.2
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        func stop() { timer?.invalidate(); timer = nil }
        deinit { timer?.invalidate() }
    }
    private var moves: Bool { enabled && animations && !reduceMotion && phase == .active && focus == .key }
    var body: some View {
        content(clock.date, moves)
            .onAppear { clock.run(moves, interval: interval) }
            .onChange(of: moves) { clock.run($0, interval: interval) }
            .onDisappear { clock.stop() }
    }
}
