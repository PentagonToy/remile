import Foundation

/// Only rendered time advances the beam. Paused windows need no timer.
struct DecorativePhaseTime {
    private(set) var elapsed: TimeInterval = 0
    var date: Date { Date(timeIntervalSinceReferenceDate: elapsed) }
    mutating func advance(by interval: TimeInterval) {
        guard interval.isFinite, interval > 0 else { return }
        elapsed += interval
    }
}
