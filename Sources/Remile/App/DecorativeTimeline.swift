import SwiftUI

@MainActor enum DecorativeMotionDiagnostics {
    private(set) static var ticks: UInt64 = 0
    static func rendered() { ticks &+= 1 }
}

/// A bounded clock for slow artwork. No display link, polling or inactive-window timer.
struct DecorativeTimeline<Content: View>: View {
    var interval: TimeInterval = 1.0 / 12
    var enabled = true
    var preservesPhase = false
    @ViewBuilder let content: (Date, Bool) -> Content
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @Environment(\.controlActiveState) private var focus
    @StateObject private var clock = DecorativeClock()
    private var moves: Bool { enabled && animations && !reduceMotion && phase == .active && focus == .key }
    var body: some View {
        content(clock.date, moves)
            .onAppear { clock.run(moves, interval: interval, preservesPhase: preservesPhase) }
            .onChange(of: moves) { clock.run($0, interval: interval, preservesPhase: preservesPhase) }
            .onDisappear { clock.stop() }
    }
}

@MainActor final class DecorativeClock: ObservableObject {
    @Published var date = Date(timeIntervalSinceReferenceDate: 0)
    private var timer: Timer?
    private var lastTick: TimeInterval?
    private var phaseTime = DecorativePhaseTime()
    func run(_ enabled: Bool, interval: TimeInterval, preservesPhase: Bool) {
        guard enabled else { stop(); return }
        guard timer == nil else { return }
        if !preservesPhase { date = Date() }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                DecorativeMotionDiagnostics.rendered()
                let now = ProcessInfo.processInfo.systemUptime
                if preservesPhase {
                    self.phaseTime.advance(by: max(0, now - (self.lastTick ?? now)))
                    self.date = self.phaseTime.date
                } else { self.date = Date() }
                self.lastTick = now
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil; lastTick = nil }
    deinit { timer?.invalidate() }
}
