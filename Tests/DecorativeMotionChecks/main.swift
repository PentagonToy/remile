import SwiftUI

MainActor.assumeIsolated {
    func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    let clock = DecorativeClock()
    clock.run(true, interval: 0.01, preservesPhase: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    clock.stop()
    let frozen = clock.date, ticks = DecorativeMotionDiagnostics.ticks
    check(frozen.timeIntervalSinceReferenceDate > 0, "An active clock advances")
    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    check(clock.date == frozen, "Inactive artwork keeps its last visible position")
    check(DecorativeMotionDiagnostics.ticks == ticks, "Inactive artwork has no timer ticks")
    clock.run(true, interval: 0.01, preservesPhase: true)
    check(clock.date == frozen, "Resume never resets the beam")
    RunLoop.current.run(until: Date().addingTimeInterval(0.04))
    clock.stop()
    let increment = clock.date.timeIntervalSince(frozen)
    check(increment > 0 && increment < 0.07, "Resume excludes paused wall time")
    print("Passed 5 decorative motion checks")
}
