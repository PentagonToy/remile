import AppKit
import SwiftUI
import ObjectiveC

/// Coalesce stepped wheel input. Precise trackpad input keeps AppKit's own momentum.
struct ScrollEase {
    var position: CGFloat
    var target: CGFloat
    mutating func add(_ delta: CGFloat, lower: CGFloat, upper: CGFloat) { target = min(upper, max(lower, target + delta)) }
    mutating func advance(seconds: TimeInterval) -> CGFloat {
        position += (target - position) * CGFloat(1 - exp(-min(0.05, max(0, seconds)) / 0.055))
        if abs(target - position) < 0.25 { position = target }
        return position
    }
}

final class NativeScrollMotion {
    private static var association: UInt8 = 0
    private weak var scroll: NSScrollView?
    private var monitor: Any?
    private var timer: Timer?
    private var ease: ScrollEase?
    private var lastTick: TimeInterval = 0
    @discardableResult static func attach(_ scroll: NSScrollView) -> NativeScrollMotion {
        if let motion = objc_getAssociatedObject(scroll, &association) as? NativeScrollMotion { return motion }
        let motion = NativeScrollMotion(scroll)
        objc_setAssociatedObject(scroll, &association, motion, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return motion
    }
    private init(_ scroll: NSScrollView) {
        self.scroll = scroll
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }; return self.handle(event)
        }
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let scroll, scroll.window === event.window else { return event }
        guard event.type == .scrollWheel else { stop(); return event }
        let point = scroll.convert(event.locationInWindow, from: nil)
        guard scroll.visibleRect.contains(point) else { return event }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !event.hasPreciseScrollingDeltas, event.phase.isEmpty, event.momentumPhase.isEmpty,
              AnimationPolicy.enabled(),
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), event.deltaY != 0 else { stop(); return event }
        return move(by: event.deltaY) ? nil : event
    }
    @discardableResult func move(by wheelDelta: CGFloat) -> Bool {
        guard AnimationPolicy.enabled(), let scroll, let document = scroll.documentView else { return false }
        let clip = scroll.contentView, lower = document.bounds.minY
        let upper = max(lower, document.bounds.maxY - clip.bounds.height)
        guard upper > lower else { return false }
        if ease == nil { ease = ScrollEase(position: clip.bounds.origin.y, target: clip.bounds.origin.y) }
        ease?.add(wheelDelta * max(1, scroll.verticalLineScroll) * (document.isFlipped ? -1 : 1), lower: lower, upper: upper)
        guard let ease, abs(ease.target - ease.position) > 0.1 else { stop(); return false }
        if timer == nil {
            lastTick = ProcessInfo.processInfo.systemUptime
            let rate = min(120, max(30, scroll.window?.screen?.maximumFramesPerSecond ?? 60))
            let timer = Timer(timeInterval: 1 / Double(rate), repeats: true) { [weak self] _ in self?.tick() }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        return true
    }
    private func tick() {
        guard let scroll, scroll.window != nil, let document = scroll.documentView, AnimationPolicy.enabled() else { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let clip = scroll.contentView, lower = document.bounds.minY, upper = max(lower, document.bounds.maxY - clip.bounds.height)
        ease?.add(0, lower: lower, upper: upper)
        guard let y = ease?.advance(seconds: now - lastTick) else { stop(); return }
        lastTick = now
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y)); scroll.reflectScrolledClipView(clip)
        if ease?.position == ease?.target { stop() }
    }
    private func stop() { timer?.invalidate(); timer = nil; ease = nil }
    deinit { timer?.invalidate(); if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// Find native scroll views only within this surface, including SwiftUI Form's scroll view.
private struct ScrollMotionAttachment: NSViewRepresentable {
    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var scope: NSView? = self.superview
                while let parent = scope {
                    if Self.containsScroll(parent) { ReaderScrolling.configure(parent); return }
                    scope = parent.superview
                }
            }
        }
        private static func containsScroll(_ view: NSView) -> Bool { view is NSScrollView || view.subviews.contains(where: containsScroll) }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.configure() }
}
extension View {
    func smoothScrolling() -> some View { background(ScrollMotionAttachment().allowsHitTesting(false)) }
}
