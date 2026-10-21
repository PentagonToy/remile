import AppKit
@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
 ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
@MainActor func wait(_ condition: () -> Bool) async -> Bool {for _ in 0..<100 {if condition(){return true};try? await Task.sleep(for:.milliseconds(15))};return false}
Task { @MainActor in
 let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:400,height:240));scroll.hasVerticalScroller=true
 scroll.documentView=FlippedDocument(frame:NSRect(x:0,y:0,width:380,height:1200))
 let window=NSWindow(contentRect:scroll.frame,styleMask:[.titled],backing:.buffered,defer:false);window.contentView=scroll;window.orderFront(nil)
 let motion=NativeScrollMotion.attach(scroll);precondition(motion===NativeScrollMotion.attach(scroll))
 let defaults = UserDefaults(suiteName: "remile.motion-checks." + UUID().uuidString)!
 precondition(AnimationPolicy.enabled(defaults: defaults, reduceMotion: false))
 defaults.set(false, forKey: AnimationPolicy.preference)
 precondition(!AnimationPolicy.enabled(defaults: defaults, reduceMotion: false))
 defaults.set(true, forKey: AnimationPolicy.preference)
 precondition(!AnimationPolicy.enabled(defaults: defaults, reduceMotion: true))
 print("Passed motion default, explicit off and system Reduced Motion policy")
 if AnimationPolicy.enabled() {
  precondition(motion.move(by:-4));let started=await wait{scroll.contentView.bounds.minY>0};precondition(started)
  precondition(motion.move(by:-4));let settled=await wait{abs(scroll.contentView.bounds.minY-80)<0.3};precondition(settled,"Stepped input did not accumulate smoothly")
  precondition(motion.move(by:-10000));let maxY=scroll.documentView!.bounds.maxY-scroll.contentView.bounds.height
  let clamped=await wait{abs(scroll.contentView.bounds.minY-maxY)<0.3};precondition(clamped,"Scroll escaped document bounds")
  print("Passed native clip-view wheel coalescing, settling and document-bound clamping")
 } else {print("Reduced Motion active: animation assertions skipped; native bypass retained")}
 window.orderOut(nil);exit(0)
}
app.run()
